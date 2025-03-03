#
# This source file is part of the EdgeDB open source project.
#
# Copyright 2016-present MagicStack Inc. and the EdgeDB authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

import asyncio
import base64
import collections
import json
import logging
import time
import statistics
import traceback
import sys

cimport cython
cimport cpython

from typing import Dict, List, Optional, Sequence, Tuple
from edb.server.protocol cimport cpythonx

from libc.stdint cimport int8_t, uint8_t, int16_t, uint16_t, \
                         int32_t, uint32_t, int64_t, uint64_t, \
                         UINT32_MAX

import immutables
from jwcrypto import jwt

from edb import buildmeta
from edb import edgeql
from edb.edgeql import qltypes

from edb.server.pgproto cimport hton
from edb.server.pgproto.pgproto cimport (
    WriteBuffer,
    ReadBuffer,

    FRBuffer,
    frb_init,
    frb_read,
    frb_read_all,
    frb_get_len,
)
from edb.server.pgproto.pgproto import UUID as pg_UUID

from edb.server.dbview cimport dbview

from edb.server import config

from edb.server import args as srvargs
from edb.server import compiler
from edb.server import defines as edbdef
from edb.server.compiler import errormech
from edb.server.compiler import enums
from edb.server.compiler import sertypes
from edb.server.protocol import execute
from edb.server.protocol cimport frontend
from edb.server.pgcon cimport pgcon
from edb.server.pgcon import errors as pgerror
from edb.server import metrics

from edb.schema import objects as s_obj

from edb import errors
from edb.errors import base as base_errors, EdgeQLSyntaxError
from edb.common import debug, taskgroup
from edb.common import context as pctx

from edb.protocol import messages


include "./consts.pxi"


cdef bytes EMPTY_TUPLE_UUID = s_obj.get_known_type_id('empty-tuple').bytes

cdef object CARD_NO_RESULT = compiler.Cardinality.NO_RESULT
cdef object CARD_AT_MOST_ONE = compiler.Cardinality.AT_MOST_ONE
cdef object CARD_MANY = compiler.Cardinality.MANY

cdef object FMT_BINARY = compiler.OutputFormat.BINARY
cdef object FMT_JSON = compiler.OutputFormat.JSON
cdef object FMT_JSON_ELEMENTS = compiler.OutputFormat.JSON_ELEMENTS
cdef object FMT_NONE = compiler.OutputFormat.NONE

cdef tuple DUMP_VER_MIN = (0, 7)
cdef tuple DUMP_VER_MAX = edbdef.CURRENT_PROTOCOL

cdef tuple MIN_PROTOCOL = edbdef.MIN_PROTOCOL
cdef tuple CURRENT_PROTOCOL = edbdef.CURRENT_PROTOCOL

cdef object logger = logging.getLogger('edb.server')
cdef object log_metrics = logging.getLogger('edb.server.metrics')

DEF QUERY_HEADER_IMPLICIT_LIMIT = 0xFF01
DEF QUERY_HEADER_IMPLICIT_TYPENAMES = 0xFF02
DEF QUERY_HEADER_IMPLICIT_TYPEIDS = 0xFF03
DEF QUERY_HEADER_ALLOW_CAPABILITIES = 0xFF04
DEF QUERY_HEADER_EXPLICIT_OBJECTIDS = 0xFF05

DEF QUERY_HEADER_DUMP_SECRETS = 0xFF10

DEF SERVER_HEADER_CAPABILITIES = 0x1001

DEF ALL_CAPABILITIES = 0xFFFFFFFFFFFFFFFF


def parse_capabilities_header(value: bytes) -> uint64_t:
    if len(value) != 8:
        raise errors.BinaryProtocolError(
            f'capabilities header must be exactly 8 bytes'
        )
    cdef uint64_t mask = hton.unpack_uint64(cpython.PyBytes_AS_STRING(value))
    return mask


def parse_catalog_version_header(value: bytes) -> uint64_t:
    if len(value) != 8:
        raise errors.BinaryProtocolError(
            f'catalog version header must be exactly 8 bytes (got {len(value)})'
        )
    cdef uint64_t catver = hton.unpack_uint64(cpython.PyBytes_AS_STRING(value))
    return catver


cdef inline bint parse_boolean(value: bytes, header: str):
    cdef bytes lower = value.lower()
    if lower == b'true':
        return True
    elif lower == b'false':
        return False
    else:
        raise errors.BinaryProtocolError(
            f'{header} header must equal "true" or "false"'
        )


cdef class EdgeConnection(frontend.FrontendConnection):

    def __init__(
        self,
        server,
        tenant,
        *,
        auth_data: bytes,
        conn_params: dict[str, str] | None,
        protocol_version: edbdef.ProtocolVersion = CURRENT_PROTOCOL,
        **kwargs,
    ):
        super().__init__(server, tenant, **kwargs)
        self._con_status = EDGECON_NEW

        self._dbview = None

        self._last_anon_compiled = None

        self.query_cache_enabled = not (debug.flags.disable_qcache or
                                        debug.flags.edgeql_compile)

        self.protocol_version = protocol_version
        self.min_protocol = MIN_PROTOCOL
        self.max_protocol = CURRENT_PROTOCOL

        self._conn_params = conn_params

        self._in_dump_restore = False

        # Authentication data supplied by the transport (e.g. the content
        # of an HTTP Authorization header).
        self._auth_data = auth_data

    cdef is_in_tx(self):
        return self.get_dbview().in_tx()

    cdef inline dbview.DatabaseConnectionView get_dbview(self):
        if self._dbview is None:
            raise RuntimeError('Cannot access dbview while it is None')
        return self._dbview

    def debug_print(self, *args):
        if self._dbview is None:
            # This may happen before dbview is initialized, e.g. sending errors
            # to non-TLS clients due to mandatory TLS.
            print(
                '::EDGEPROTO::',
                f'id:{self._id}',
                f'in_tx:{0}',
                f'tx_error:{0}',
                *args,
                file=sys.stderr,
            )
        else:
            print(
                '::EDGEPROTO::',
                f'id:{self._id}',
                f'in_tx:{int(self._dbview.in_tx())}',
                f'tx_error:{int(self._dbview.in_tx_error())}',
                *args,
                file=sys.stderr,
            )

    def is_idle(self, expiry_time: float):
        # A connection is idle if it awaits for the next message for
        # client for too long (even if it is in an open transaction!)
        return (
            self._con_status != EDGECON_BAD and
            super().is_idle(expiry_time) and
            not self._in_dump_restore
        )

    def is_alive(self):
        return self._con_status == EDGECON_STARTED and super().is_alive()

    def close_for_idling(self):
        try:
            self.write_error(
                errors.IdleSessionTimeoutError(
                    'closing the connection due to idling')
            )
        finally:
            self.close()  # will flush

    cdef _after_idling(self):
        self.server.on_binary_client_after_idling(self)

    async def do_handshake(self):
        cdef:
            char mtype

        if self._transport_proto is srvargs.ServerConnTransport.HTTP:
            if self._conn_params is None:
                params = {}
            else:
                params = self._conn_params
        else:
            await self.wait_for_message(report_idling=True)
            mtype = self.buffer.get_message_type()
            if mtype != b'V':
                raise errors.BinaryProtocolError(
                    f'unexpected initial message: "{chr(mtype)}", '
                    f'expected "V"')

            params = await self._do_handshake()
            if self._conn_params is not None:
                params = self._conn_params + params

        return params

    async def auth(self, params):
        cdef:
            WriteBuffer msg_buf
            WriteBuffer buf

        user = params.get('user')
        if not user:
            raise errors.BinaryProtocolError(
                f'missing required connection parameter in ClientHandshake '
                f'message: "user"'
            )

        database = params.get('database')
        if not database:
            raise errors.BinaryProtocolError(
                f'missing required connection parameter in ClientHandshake '
                f'message: "database"'
            )

        logger.debug('received connection request by %s to database %s',
                     user, database)

        await self._authenticate(user, database, params)

        logger.debug('successfully authenticated %s in database %s',
                     user, database)

        if not self.tenant.is_database_connectable(database):
            raise errors.AccessError(
                f'database {database!r} does not accept connections'
            )

        await self._start_connection(database)

        self.dbname = database
        self.username = user

        if self._transport_proto is srvargs.ServerConnTransport.HTTP:
            return

        buf = WriteBuffer()

        msg_buf = WriteBuffer.new_message(b'R')
        msg_buf.write_int32(0)
        msg_buf.end_message()
        buf.write_buffer(msg_buf)

        msg_buf = WriteBuffer.new_message(b'K')
        # TODO: should send ID of this connection
        msg_buf.write_bytes(b'\x00' * 32)
        msg_buf.end_message()
        buf.write_buffer(msg_buf)

        if self.get_dbview().get_state_serializer() is None:
            await self.get_dbview().reload_state_serializer()
        buf.write_buffer(self.make_state_data_description_msg())

        self.write(buf)

        if self.server.in_dev_mode():
            pgaddr = dict(self.tenant.get_pgaddr())
            if pgaddr.get('password'):
                pgaddr['password'] = '********'
            pgaddr['database'] = self.tenant.get_pg_dbname(
                self.get_dbview().dbname
            )
            pgaddr.pop('ssl', None)
            if 'sslmode' in pgaddr:
                pgaddr['sslmode'] = pgaddr['sslmode'].name
            self.write_status(b'pgaddr', json.dumps(pgaddr).encode())

        self.write_status(
            b'suggested_pool_concurrency',
            str(self.tenant.suggested_client_pool_size).encode()
        )
        self.write_status(
            b'system_config',
            self.tenant.get_report_config_data(self.protocol_version),
        )

        self.write(self.sync_status())

        self.flush()

    async def _do_handshake(self):
        cdef:
            uint16_t major
            uint16_t minor
            int i
            uint16_t reserved
            dict params = {}

        major = <uint16_t>self.buffer.read_int16()
        minor = <uint16_t>self.buffer.read_int16()

        self.protocol_version = major, minor

        nparams = <uint16_t>self.buffer.read_int16()
        for i in range(nparams):
            k = self.buffer.read_len_prefixed_utf8()
            v = self.buffer.read_len_prefixed_utf8()
            params[k] = v

        reserved = <uint16_t>self.buffer.read_int16()
        if reserved != 0:
            raise errors.BinaryProtocolError(
                f'unexpected value in reserved field of ClientHandshake')

        self.buffer.finish_message()

        negotiate = False
        if self.protocol_version < self.min_protocol:
            target_proto = self.min_protocol
            negotiate = True
        elif self.protocol_version > self.max_protocol:
            target_proto = self.max_protocol
            negotiate = True
        else:
            target_proto = self.protocol_version

        if negotiate:
            self.write(self.make_negotiate_protocol_version_msg(target_proto))
            self.flush()

        return params

    async def _start_connection(self, database: str) -> None:
        dbv = await self.tenant.new_dbview(
            dbname=database,
            query_cache=self.query_cache_enabled,
            protocol_version=self.protocol_version,
        )
        assert type(dbv) is dbview.DatabaseConnectionView
        self._dbview = <dbview.DatabaseConnectionView>dbv
        self.dbname = database

        self._con_status = EDGECON_STARTED

    cdef stop_connection(self):
        self._con_status = EDGECON_BAD

        if self._dbview is not None:
            self.tenant.remove_dbview(self._dbview)
            self._dbview = None

    def _extract_token_from_auth_data(self, auth_data):
        header_value = auth_data.decode("ascii")
        scheme, _, prefixed_token = header_value.partition(" ")
        if scheme.lower() != "bearer":
            raise errors.AuthenticationError(
                'authentication failed: unrecognized authentication scheme')

        return prefixed_token.strip()

    def _auth_jwt(self, user, database, params):
        # token in the HTTP header has higher priority than
        # the ClientHandshake message, under the scenario of
        # binary protocol over HTTP
        if self._auth_data:
            prefixed_token = self._extract_token_from_auth_data(
                self._auth_data
            )
        else:
            prefixed_token = params.get('secret_key')

        if not prefixed_token:
            raise errors.AuthenticationError(
                'authentication failed: no authorization data provided')

        token_version = 0
        for prefix in ["nbwt1_", "nbwt_", "edbt1_", "edbt_"]:
            encoded_token = prefixed_token.removeprefix(prefix)
            if encoded_token != prefixed_token:
                if prefix == "nbwt1_" or prefix == "edbt1_":
                    token_version = 1
                break
        else:
            raise errors.AuthenticationError(
                'authentication failed: malformed JWT')

        role = self.tenant.get_roles().get(user)
        if role is None:
            raise errors.AuthenticationError('authentication failed')

        skey = self.server.get_jws_key()

        try:
            token = jwt.JWT(
                key=skey,
                algs=["RS256", "ES256"],
                jwt=encoded_token,
            )
        except jwt.JWException as e:
            logger.debug('authentication failure', exc_info=True)
            raise errors.AuthenticationError(
                f'authentication failed: {e.args[0]}'
            ) from None
        except Exception as e:
            logger.debug('authentication failure', exc_info=True)
            raise errors.AuthenticationError(
                f'authentication failed: cannot decode JWT'
            ) from None

        try:
            claims = json.loads(token.claims)
        except Exception as e:
            raise errors.AuthenticationError(
                f'authentication failed: malformed claims section in JWT'
            ) from None

        self._check_jwt_authz(claims, token_version, user, database)

    def _check_jwt_authz(self, claims, token_version, user, dbname):
        # Check general key validity (e.g. whether it's a revoked key)
        self.tenant.check_jwt(claims)

        token_instances = None
        token_roles = None
        token_databases = None

        if token_version == 1:
            token_roles = self._get_jwt_edb_scope(claims, "edb.r")
            token_instances = self._get_jwt_edb_scope(claims, "edb.i")
            token_databases = self._get_jwt_edb_scope(claims, "edb.d")
        else:
            namespace = "edgedb.server"
            if not claims.get(f"{namespace}.any_role"):
                token_roles = claims.get(f"{namespace}.roles")
                if not isinstance(token_roles, list):
                    raise errors.AuthenticationError(
                        f'authentication failed: malformed claims section in'
                        f' JWT: expected a list in "{namespace}.roles"'
                    )

        if (
            token_instances is not None
            and self.tenant.get_instance_name() not in token_instances
        ):
            raise errors.AuthenticationError(
                'authentication failed: secret key does not authorize '
                f'access to this instance')

        if (
            token_databases is not None
            and dbname not in token_databases
        ):
            raise errors.AuthenticationError(
                'authentication failed: secret key does not authorize '
                f'access to database "{dbname}"')

        if token_roles is not None and user not in token_roles:
            raise errors.AuthenticationError(
                'authentication failed: secret key does not authorize '
                f'access in role "{user}"')

    def _get_jwt_edb_scope(self, claims, claim):
        if not claims.get(f"{claim}.all"):
            scope = claims.get(claim, [])
            if not isinstance(scope, list):
                raise errors.AuthenticationError(
                    f'authentication failed: malformed claims section in'
                    f' JWT: expected a list in "{claim}"'
                )
            return frozenset(scope)
        else:
            return None

    cdef WriteBuffer _make_authentication_sasl_initial(self, list methods):
        cdef WriteBuffer msg_buf
        msg_buf = WriteBuffer.new_message(b'R')
        msg_buf.write_int32(10)
        # Number of auth methods followed by a series
        # of zero-terminated strings identifying each method,
        # sorted in the order of server preference.
        msg_buf.write_int32(len(methods))
        for method in methods:
            msg_buf.write_len_prefixed_bytes(method)
        return msg_buf.end_message()

    cdef _expect_sasl_initial_response(self):
        mtype = self.buffer.get_message_type()
        if mtype != b'p':
            raise errors.BinaryProtocolError(
                f'expected SASL response, got message type {mtype}')
        selected_mech = self.buffer.read_len_prefixed_bytes()
        client_first = self.buffer.read_len_prefixed_bytes()
        self.buffer.finish_message()
        if not client_first:
            # The client didn't send the Client Initial Response
            # in SASLInitialResponse, this is an error.
            raise errors.BinaryProtocolError(
                f'client did not send the Client Initial Response '
                f'data in SASLInitialResponse')
        return selected_mech, client_first

    cdef WriteBuffer _make_authentication_sasl_msg(
        self, bytes data, bint final
    ):
        cdef WriteBuffer msg_buf
        msg_buf = WriteBuffer.new_message(b'R')
        if final:
            msg_buf.write_int32(12)
        else:
            msg_buf.write_int32(11)
        msg_buf.write_len_prefixed_bytes(data)
        return msg_buf.end_message()

    cdef bytes _expect_sasl_response(self):
        mtype = self.buffer.get_message_type()
        if mtype != b'r':
            raise errors.BinaryProtocolError(
                f'expected SASL response, got message type {mtype}')
        client_final = self.buffer.read_len_prefixed_bytes()
        self.buffer.finish_message()
        return client_final

    async def _execute_script(self, compiled: object, bind_args: bytes):
        cdef:
            pgcon.PGConnection conn
            dbview.DatabaseConnectionView dbv

        if self._cancelled:
            raise ConnectionAbortedError

        dbv = self.get_dbview()
        conn = await self.get_pgcon()

        try:
            await execute.execute_script(
                conn,
                dbv,
                compiled,
                bind_args,
                fe_conn=self,
            )
        finally:
            self.maybe_release_pgcon(conn)

    def _tokenize(self, eql: bytes) -> edgeql.Source:
        text = eql.decode('utf-8')
        if debug.flags.edgeql_disable_normalization:
            return edgeql.Source.from_string(text)
        else:
            return edgeql.NormalizedSource.from_string(text)

    async def _parse(
        self,
        dbview.QueryRequestInfo query_req,
    ) -> dbview.CompiledQuery:
        cdef dbview.DatabaseConnectionView dbv
        dbv = self.get_dbview()
        if self.debug:
            source = query_req.source
            text = source.text()
            self.debug_print('PARSE', text)
            self.debug_print(
                'Cache key',
                source.cache_key(),
                f"protocol_version={query_req.protocol_version}",
                f"output_format={query_req.output_format}",
                f"expect_one={query_req.expect_one}",
                f"implicit_limit={query_req.implicit_limit}",
                f"inline_typeids={query_req.inline_typeids}",
                f"inline_typenames={query_req.inline_typenames}",
                f"inline_objectids={query_req.inline_objectids}",
                f"allow_capabilities={query_req.allow_capabilities}",
                f"modaliazes={dbv.get_modaliases()}",
                f"session_config={dbv.get_session_config()}",
            )
            self.debug_print('Extra variables', source.variables(),
                             'after', source.first_extra())

        return await dbv.parse(query_req)

    cdef parse_cardinality(self, bytes card):
        if card[0] == CARD_MANY.value:
            return CARD_MANY
        elif card[0] == CARD_AT_MOST_ONE.value:
            return CARD_AT_MOST_ONE
        else:
            try:
                card_name = compiler.Cardinality(card[0]).name
            except ValueError:
                raise errors.BinaryProtocolError(
                    f'unknown expected cardinality "{repr(card)[2:-1]}"')
            else:
                raise errors.BinaryProtocolError(
                    f'cardinality {card_name} cannot be requested')

    cdef char render_cardinality(self, query_unit_group) except -1:
        return query_unit_group.cardinality.value

    cdef parse_output_format(self, bytes mode):
        if mode == b'j':
            return FMT_JSON
        elif mode == b'J':
            return FMT_JSON_ELEMENTS
        elif mode == b'b':
            return FMT_BINARY
        elif mode == b'n':
            return FMT_NONE
        else:
            raise errors.BinaryProtocolError(
                f'unknown output mode "{repr(mode)[2:-1]}"')

    cdef inline reject_headers(self):
        cdef int16_t nheaders = self.buffer.read_int16()
        if nheaders != 0:
            raise errors.BinaryProtocolError('unexpected headers')

    cdef dict parse_headers(self):
        cdef:
            dict attrs
            uint16_t num_fields
            uint16_t key
            bytes value

        attrs = {}
        num_fields = <uint16_t>self.buffer.read_int16()
        while num_fields:
            key = <uint16_t>self.buffer.read_int16()
            value = self.buffer.read_len_prefixed_bytes()
            attrs[key] = value
            num_fields -= 1
        return attrs

    cdef inline ignore_headers(self):
        cdef:
            uint16_t num_fields

        num_fields = <uint16_t>self.buffer.read_int16()
        while num_fields:
            self.buffer.read_int16()
            self.buffer.read_len_prefixed_bytes()
            num_fields -= 1

    #############

    cdef WriteBuffer make_negotiate_protocol_version_msg(
        self,
        tuple target_proto,
    ):
        cdef:
            WriteBuffer msg

        # NegotiateProtocolVersion
        msg = WriteBuffer.new_message(b'v')
        # Highest supported major version of the protocol.
        msg.write_int16(target_proto[0])
        # Highest supported minor version of the protocol.
        msg.write_int16(target_proto[1])
        # No extensions are currently supported.
        msg.write_int16(0)

        msg.end_message()
        return msg

    cdef WriteBuffer make_command_data_description_msg(
        self, dbview.CompiledQuery query
    ):
        cdef:
            WriteBuffer msg

        msg = WriteBuffer.new_message(b'T')
        msg.write_int16(0)  # no headers
        msg.write_int64(<int64_t><uint64_t>query.query_unit_group.capabilities)
        msg.write_byte(self.render_cardinality(query.query_unit_group))

        in_data = query.query_unit_group.in_type_data
        msg.write_bytes(query.query_unit_group.in_type_id)
        msg.write_len_prefixed_bytes(in_data)

        out_data = query.query_unit_group.out_type_data
        msg.write_bytes(query.query_unit_group.out_type_id)
        msg.write_len_prefixed_bytes(out_data)

        msg.end_message()
        return msg

    cdef WriteBuffer make_state_data_description_msg(self):
        cdef WriteBuffer msg

        type_id, type_data = self.get_dbview().describe_state()

        msg = WriteBuffer.new_message(b's')
        msg.write_bytes(type_id.bytes)
        msg.write_len_prefixed_bytes(type_data)
        msg.end_message()

        return msg

    cdef WriteBuffer make_command_complete_msg(self, capabilities, status):
        cdef:
            WriteBuffer msg

        state_tid, state_data = self.get_dbview().encode_state()

        msg = WriteBuffer.new_message(b'C')
        msg.write_int16(0)  # no headers
        msg.write_int64(<int64_t><uint64_t>capabilities)
        msg.write_len_prefixed_bytes(status)

        msg.write_bytes(state_tid.bytes)
        msg.write_len_prefixed_bytes(state_data)

        return msg.end_message()

    async def _execute_rollback(self, compiled: dbview.CompiledQuery):
        cdef:
            dbview.DatabaseConnectionView _dbview
            pgcon.PGConnection conn

        query_unit = compiled.query_unit_group[0]
        _dbview = self.get_dbview()
        if not (
            query_unit.tx_savepoint_rollback or
            query_unit.tx_rollback or
            query_unit.tx_abort_migration
        ):
            _dbview.raise_in_tx_error()

        conn = await self.get_pgcon()
        try:
            if query_unit.sql:
                await conn.sql_execute(query_unit.sql)

            if query_unit.tx_abort_migration:
                _dbview.clear_tx_error()
            elif query_unit.tx_savepoint_rollback:
                _dbview.rollback_tx_to_savepoint(query_unit.sp_name)
            else:
                assert query_unit.tx_rollback
                _dbview.abort_tx()
        finally:
            self.maybe_release_pgcon(conn)

    async def _execute(
        self,
        compiled: dbview.CompiledQuery,
        bind_args: bytes,
        use_prep_stmt: bint,
    ):
        cdef:
            dbview.DatabaseConnectionView dbv
            pgcon.PGConnection conn

        dbv = self.get_dbview()
        conn = await self.get_pgcon()
        try:
            await execute.execute(
                conn,
                dbv,
                compiled,
                bind_args,
                fe_conn=self,
                use_prep_stmt=use_prep_stmt,
            )
        finally:
            self.maybe_release_pgcon(conn)

        query_unit = compiled.query_unit_group[0]
        if query_unit.config_requires_restart:
            self.write_log(
                EdgeSeverity.EDGE_SEVERITY_NOTICE,
                errors.LogMessage.get_code(),
                'server restart is required for the configuration '
                'change to take effect')

    cdef dbview.QueryRequestInfo parse_execute_request(self):
        cdef:
            uint64_t allow_capabilities = 0
            uint64_t compilation_flags = 0
            int64_t implicit_limit = 0
            bint inline_typenames = False
            bint inline_typeids = False
            bint inline_objectids = False
            object output_format
            bint expect_one = False
            bytes query

        allow_capabilities = <uint64_t>self.buffer.read_int64()
        compilation_flags = <uint64_t>self.buffer.read_int64()
        implicit_limit = self.buffer.read_int64()

        if implicit_limit < 0:
            raise errors.BinaryProtocolError(
                f'implicit limit cannot be negative'
            )

        inline_typenames = (
            compilation_flags
            & messages.CompilationFlag.INJECT_OUTPUT_TYPE_NAMES
        )
        inline_typeids = (
            compilation_flags
            & messages.CompilationFlag.INJECT_OUTPUT_TYPE_IDS
        )
        inline_objectids = (
            compilation_flags
            & messages.CompilationFlag.INJECT_OUTPUT_OBJECT_IDS
        )

        output_format = self.parse_output_format(self.buffer.read_byte())
        expect_one = (
            self.parse_cardinality(self.buffer.read_byte()) is CARD_AT_MOST_ONE
        )

        query = self.buffer.read_len_prefixed_bytes()
        if not query:
            raise errors.BinaryProtocolError('empty query')

        state_tid = self.buffer.read_bytes(16)
        state_data = self.buffer.read_len_prefixed_bytes()
        try:
            self.get_dbview().decode_state(state_tid, state_data)
        except errors.StateMismatchError:
            self.write(self.make_state_data_description_msg())
            raise

        return dbview.QueryRequestInfo(
            self._tokenize(query),
            self.protocol_version,
            output_format=output_format,
            expect_one=expect_one,
            implicit_limit=implicit_limit,
            inline_typeids=inline_typeids,
            inline_typenames=inline_typenames,
            inline_objectids=inline_objectids,
            allow_capabilities=allow_capabilities,
        )

    async def parse(self):
        cdef:
            bytes eql
            dbview.QueryRequestInfo query_req
            dbview.DatabaseConnectionView _dbview
            WriteBuffer parse_complete
            WriteBuffer buf

        self._last_anon_compiled = None

        self.ignore_headers()

        _dbview = self.get_dbview()
        if _dbview.get_state_serializer() is None:
            await _dbview.reload_state_serializer()
        query_req = self.parse_execute_request()
        compiled = await self._parse(query_req)

        buf = self.make_command_data_description_msg(compiled)

        # Cache compilation result in anticipation that the client
        # will follow up with an Execute immediately.
        #
        # N.B.: we cannot rely on query cache because not all units
        # are cacheable.
        self._last_anon_compiled = compiled
        self._last_anon_compiled_hash = hash(query_req)

        self.write(buf)
        self.flush()

    async def execute(self):
        cdef:
            dbview.QueryRequestInfo query_req
            dbview.DatabaseConnectionView _dbview
            bytes in_tid
            bytes out_tid
            bytes args

        self.ignore_headers()

        _dbview = self.get_dbview()
        if _dbview.get_state_serializer() is None:
            await _dbview.reload_state_serializer()
        query_req = self.parse_execute_request()
        in_tid = self.buffer.read_bytes(16)
        out_tid = self.buffer.read_bytes(16)
        args = self.buffer.read_len_prefixed_bytes()

        self.buffer.finish_message()

        if (
            self._last_anon_compiled is not None and
            hash(query_req) == self._last_anon_compiled_hash and
            in_tid == self._last_anon_compiled.query_unit_group.in_type_id and
            out_tid == self._last_anon_compiled.query_unit_group.out_type_id
        ):
            compiled = self._last_anon_compiled
            query_unit_group = compiled.query_unit_group
        else:
            query_unit_group = _dbview.lookup_compiled_query(query_req)
            if query_unit_group is None:
                if self.debug:
                    self.debug_print('EXECUTE /CACHE MISS', query_req.source.text())

                compiled = await self._parse(query_req)
                query_unit_group = compiled.query_unit_group
                if self._cancelled:
                    raise ConnectionAbortedError
            else:
                compiled = dbview.CompiledQuery(
                    query_unit_group=query_unit_group,
                    first_extra=query_req.source.first_extra(),
                    extra_counts=query_req.source.extra_counts(),
                    extra_blobs=query_req.source.extra_blobs(),
                )

        # Clear the _last_anon_compiled so that the next Execute - if
        # identical - will always lookup in the cache and honor the
        # `cacheable` flag to compile the query again.
        self._last_anon_compiled = None

        _dbview.check_capabilities(
            query_unit_group.capabilities,
            query_req.allow_capabilities,
            errors.DisabledCapabilityError,
            "disabled by the client",
        )

        if query_unit_group.in_type_id != in_tid:
            self.write(self.make_command_data_description_msg(compiled))
            raise errors.ParameterTypeMismatchError(
                "specified parameter type(s) do not match the parameter "
                "types inferred from specified command(s)"
            )

        if query_unit_group.out_type_id != out_tid:
            # The client has no up-to-date information about the output,
            # so provide one.
            self.write(self.make_command_data_description_msg(compiled))

        if self.debug:
            self.debug_print('EXECUTE', query_req.source.text())

        metrics.edgeql_query_compilations.inc(1.0, 'cache')
        force_script = any(x.needs_readback for x in query_unit_group)
        if (
            _dbview.in_tx_error()
            or query_unit_group[0].tx_savepoint_rollback
            or query_unit_group[0].tx_abort_migration
        ):
            assert len(query_unit_group) == 1
            await self._execute_rollback(compiled)
        elif len(query_unit_group) > 1 or force_script:
            await self._execute_script(compiled, args)
        else:
            use_prep = (
                len(query_unit_group) == 1
                and bool(query_unit_group[0].sql_hash)
            )
            await self._execute(compiled, args, use_prep)

        if self._cancelled:
            raise ConnectionAbortedError

        if _dbview.is_state_desc_changed():
            self.write(self.make_state_data_description_msg())
        self.write(
            self.make_command_complete_msg(
                compiled.query_unit_group.capabilities,
                compiled.query_unit_group[-1].status,
            )
        )
        self.flush()

    async def sync(self):
        self.buffer.consume_message()
        self.write(self.sync_status())

        if self.debug:
            self.debug_print('SYNC')

        self.flush()

    def check_readiness(self):
        if self.tenant.is_blocked():
            readiness_reason = self.tenant.get_readiness_reason()
            msg = "the server is not accepting requests"
            if readiness_reason:
                msg = f"{msg}: {readiness_reason}"
            raise errors.ServerBlockedError(msg)
        elif not self.tenant.is_online():
            readiness_reason = self.tenant.get_readiness_reason()
            msg = "the server is going offline"
            if readiness_reason:
                msg = f"{msg}: {readiness_reason}"
            raise errors.ServerOfflineError(msg)

    async def authenticate(self):
        self.check_readiness()
        params = await self.do_handshake()
        await self.auth(params)
        self.server.on_binary_client_authed(self)

    async def main_step(self, char mtype):
        try:
            self.check_readiness()

            if mtype == b'O':
                await self.execute()

            elif mtype == b'P':
                await self.parse()

            elif mtype == b'S':
                await self.sync()

            elif mtype == b'X':
                self.close()
                return True

            elif mtype == b'>':
                await self.dump()

            elif mtype == b'<':
                # The restore protocol cannot send SYNC beforehand,
                # so if an error occurs the server should send an
                # ERROR message immediately.
                await self.restore()

            elif mtype == b'D':
                raise errors.BinaryProtocolError(
                    "Describe message (D) is not supported in "
                    "protocol versions greater than 0.13")

            elif mtype == b'E':
                raise errors.BinaryProtocolError(
                    "Legacy Execute message (E) is not supported in "
                    "protocol versions greater than 0.13")

            elif mtype == b'Q':
                raise errors.BinaryProtocolError(
                    "ExecuteScript message (Q) is not supported in "
                    "protocol versions greater then 0.13")

            else:
                self.fallthrough()

        except ConnectionError:
            raise

        except asyncio.CancelledError:
            raise

        except Exception as ex:
            if self._cancelled and \
                    isinstance(ex, pgerror.BackendQueryCancelledError):
                # If we are cancelling the protocol (means that the
                # client side of the connection has dropped and we
                # need to gracefull cleanup and abort) we want to
                # propagate the BackendQueryCancelledError exception.
                #
                # If we're not cancelling, we'll treat it just like
                # any other error coming from Postgres (a query
                # might get cancelled due to a variety of reasons.)
                raise

            # The connection has been aborted; there's nothing
            # we can do except shutting this down.
            if self._con_status == EDGECON_BAD:
                return True

            self.get_dbview().tx_error()
            self.buffer.finish_message()

            ex = await self.interpret_error(ex)

            self.write_error(ex)

            if isinstance(
                ex,
                (errors.ServerOfflineError, errors.ServerBlockedError),
            ):
                # This server is going into "offline" or "blocked" mode,
                # close the connection.
                self.write(self.sync_status())
                self.flush()
                self.close()
                return

            self.flush()

            # The connection was aborted while we were
            # interpreting the error (via compiler/errmech.py).
            if self._con_status == EDGECON_BAD:
                return True

            await self.recover_from_error()

        else:
            self.buffer.finish_message()

    cdef _main_task_stopped_normally(self):
        self.write_log(
            EdgeSeverity.EDGE_SEVERITY_NOTICE,
            errors.LogMessage.get_code(),
            'server is stopped; disconnecting now')

    async def recover_from_error(self):
        # Consume all messages until sync.

        while True:

            if not self.buffer.take_message():
                await self.wait_for_message(report_idling=True)
            mtype = self.buffer.get_message_type()

            if mtype == b'S':
                await self.sync()
                return
            else:
                self.buffer.discard_message()

    cdef write_error(self, exc):
        cdef:
            WriteBuffer buf
            int16_t fields_len

        exc_type = type(exc)
        # Not all calls to write_error went through interpret_error, so we
        # do this check here also.
        if not issubclass(exc_type, errors.EdgeDBError):
            exc_type = errors.InternalServerError

        if self.debug and not isinstance(exc, errors.BackendUnavailableError):
            self.debug_print('EXCEPTION', type(exc).__name__, exc)
            from edb.common.markup import dump
            dump(exc)

        if debug.flags.server and not isinstance(
            exc, errors.BackendUnavailableError
        ):
            self.loop.call_exception_handler({
                'message': (
                    'an error in edgedb protocol'
                ),
                'exception': exc,
                'protocol': self,
                'transport': self._transport,
        })

        exc_code = None

        fields = {}
        if isinstance(exc, errors.EdgeDBError):
            fields.update(exc._attrs)

        exc_code = exc_type.get_code()
        if (exc_type is errors.InternalServerError
                and not fields.get(base_errors.FIELD_HINT)):
            fields[base_errors.FIELD_HINT] = (
                f'This is most likely a bug in EdgeDB. '
                f'Please consider opening an issue ticket '
                f'at https://github.com/edgedb/edgedb/issues/new'
                f'?template=bug_report.md'
            )

        try:
            formatted_error = exc.__formatted_error__
        except AttributeError:
            try:
                formatted_error = ''.join(
                    traceback.format_exception(
                        type(exc), exc, exc.__traceback__,
                        limit=50))
            except Exception:
                formatted_error = 'could not serialize error traceback'

        fields[base_errors.FIELD_SERVER_TRACEBACK] = formatted_error

        buf = WriteBuffer.new_message(b'E')
        buf.write_byte(<char><uint8_t>EdgeSeverity.EDGE_SEVERITY_ERROR)
        buf.write_int32(<int32_t><uint32_t>exc_code)
        buf.write_len_prefixed_utf8(str(exc))
        buf.write_int16(len(fields))
        for k, v in fields.items():
            buf.write_int16(<int16_t><uint16_t>k)
            buf.write_len_prefixed_utf8(str(v))
        buf.end_message()

        self.write(buf)

    async def interpret_error(self, exc):
        dbv = self.get_dbview()
        return await execute.interpret_error(
            exc,
            dbv._db,
            global_schema_pickle=dbv.get_global_schema_pickle(),
            user_schema_pickle=dbv.get_user_schema_pickle(),
        )

    cdef write_status(self, bytes name, bytes value):
        cdef:
            WriteBuffer buf

        buf = WriteBuffer.new_message(b'S')
        buf.write_len_prefixed_bytes(name)
        buf.write_len_prefixed_bytes(value)
        buf.end_message()

        self.write(buf)

    cdef write_log(self, EdgeSeverity severity, uint32_t code, str message):
        cdef:
            WriteBuffer buf

        if severity >= EdgeSeverity.EDGE_SEVERITY_ERROR:
            # This is an assertion.
            raise errors.InternalServerError(
                'emitting a log message with severity=ERROR')

        buf = WriteBuffer.new_message(b'L')
        buf.write_byte(<char><uint8_t>severity)
        buf.write_int32(<int32_t><uint32_t>code)
        buf.write_len_prefixed_utf8(message)
        buf.write_int16(0)  # number of headers
        buf.end_message()

        self.write(buf)

    cdef sync_status(self):
        cdef:
            WriteBuffer buf
            dbview.DatabaseConnectionView _dbview

        buf = WriteBuffer.new_message(b'Z')
        buf.write_int16(0)  # no headers

        # NOTE: EdgeDB and PostgreSQL current statuses can disagree.
        # For example, Postres can be "PQTRANS_INTRANS" whereas EdgeDB
        # would be "PQTRANS_INERROR". This can happen becuase some of
        # EdgeDB errors can happen at the compile stage, not even
        # reaching Postgres.

        _dbview = self.get_dbview()
        if _dbview.in_tx_error():
            buf.write_byte(b'E')
        elif _dbview.in_tx():
            buf.write_byte(b'T')
        else:
            buf.write_byte(b'I')

        return buf.end_message()

    cdef fallthrough(self):
        cdef:
            char mtype = self.buffer.get_message_type()

        if mtype == b'H':
            # Flush
            self.buffer.discard_message()
            self.flush()

        elif mtype == b'X':
            # Terminate
            self.buffer.discard_message()
            self.close()

        else:
            raise errors.BinaryProtocolError(
                f'unexpected message type {chr(mtype)!r}')

    def connection_made(self, transport):
        if self._con_status != EDGECON_NEW:
            raise errors.BinaryProtocolError(
                'invalid connection status while establishing the connection')
        super().connection_made(transport)

    cdef _main_task_created(self):
        self.server.on_binary_client_connected(self)

    def connection_lost(self, exc):
        self.server.on_binary_client_disconnected(self)
        super().connection_lost(exc)

    async def dump(self):
        cdef:
            WriteBuffer msg_buf
            dbview.DatabaseConnectionView _dbview

        headers = self.parse_headers()
        include_secrets = headers.get(QUERY_HEADER_DUMP_SECRETS) == b'\x01'

        self.buffer.finish_message()

        _dbview = self.get_dbview()
        if _dbview.txid:
            raise errors.ProtocolError(
                'DUMP must not be executed while in transaction'
            )

        server = self.server
        compiler_pool = server.get_compiler_pool()

        dbname = _dbview.dbname
        tenant = self.tenant
        pgcon = await tenant.acquire_pgcon(dbname)
        self._in_dump_restore = True
        try:
            # To avoid having races, we want to:
            #
            #   1. start a transaction;
            #
            #   2. in the compiler process we connect to that transaction
            #      and re-introspect the schema in it.
            #
            #   3. all dump worker pg connection would work on the same
            #      connection.
            #
            # This guarantees that every pg connection and the compiler work
            # with the same DB state.

            await pgcon.sql_execute(
                b'''START TRANSACTION
                        ISOLATION LEVEL SERIALIZABLE
                        READ ONLY
                        DEFERRABLE;

                    -- Disable transaction or query execution timeout
                    -- limits. Both clients and the server can be slow
                    -- during the dump/restore process.
                    SET LOCAL idle_in_transaction_session_timeout = 0;
                    SET LOCAL statement_timeout = 0;
                ''',
            )

            user_schema_json = await server.introspect_user_schema_json(pgcon)
            global_schema_json = (
                await server.introspect_global_schema_json(pgcon)
            )
            db_config_json = await server.introspect_db_config(pgcon)
            dump_protocol = self.max_protocol

            schema_ddl, schema_dynamic_ddl, schema_ids, blocks = (
                await compiler_pool.describe_database_dump(
                    user_schema_json,
                    global_schema_json,
                    db_config_json,
                    dump_protocol,
                    include_secrets,
                )
            )

            if schema_dynamic_ddl:
                for query in schema_dynamic_ddl:
                    result = await pgcon.sql_fetch_val(query.encode('utf-8'))
                    if result:
                        schema_ddl += '\n' + result.decode('utf-8')

            msg_buf = WriteBuffer.new_message(b'@')

            msg_buf.write_int16(4)  # number of headers
            msg_buf.write_int16(DUMP_HEADER_BLOCK_TYPE)
            msg_buf.write_len_prefixed_bytes(DUMP_HEADER_BLOCK_TYPE_INFO)
            msg_buf.write_int16(DUMP_HEADER_SERVER_VER)
            msg_buf.write_len_prefixed_utf8(str(buildmeta.get_version()))
            msg_buf.write_int16(DUMP_HEADER_SERVER_CATALOG_VERSION)
            msg_buf.write_int32(8)
            msg_buf.write_int64(buildmeta.EDGEDB_CATALOG_VERSION)
            msg_buf.write_int16(DUMP_HEADER_SERVER_TIME)
            msg_buf.write_len_prefixed_utf8(str(int(time.time())))

            msg_buf.write_int16(dump_protocol[0])
            msg_buf.write_int16(dump_protocol[1])
            msg_buf.write_len_prefixed_utf8(schema_ddl)

            msg_buf.write_int32(len(schema_ids))
            for (tn, td, tid) in schema_ids:
                msg_buf.write_len_prefixed_utf8(tn)
                msg_buf.write_len_prefixed_utf8(td)
                assert len(tid) == 16
                msg_buf.write_bytes(tid)  # uuid

            msg_buf.write_int32(len(blocks))
            for block in blocks:
                assert len(block.schema_object_id.bytes) == 16
                msg_buf.write_bytes(block.schema_object_id.bytes)  # uuid
                msg_buf.write_len_prefixed_bytes(block.type_desc)

                msg_buf.write_int16(len(block.schema_deps))
                for depid in block.schema_deps:
                    assert len(depid.bytes) == 16
                    msg_buf.write_bytes(depid.bytes)  # uuid

            self._transport.write(memoryview(msg_buf.end_message()))
            self.flush()

            blocks_queue = collections.deque(blocks)
            output_queue = asyncio.Queue(maxsize=2)

            async with taskgroup.TaskGroup() as g:
                g.create_task(pgcon.dump(
                    blocks_queue,
                    output_queue,
                    DUMP_BLOCK_SIZE,
                ))

                nstops = 0
                while True:
                    if self._cancelled:
                        raise ConnectionAbortedError

                    out = await output_queue.get()
                    if out is None:
                        nstops += 1
                        if nstops == 1:
                            # we only have one worker right now
                            break
                    else:
                        block, block_num, data = out

                        msg_buf = WriteBuffer.new_message(b'=')
                        msg_buf.write_int16(4)  # number of headers

                        msg_buf.write_int16(DUMP_HEADER_BLOCK_TYPE)
                        msg_buf.write_len_prefixed_bytes(
                            DUMP_HEADER_BLOCK_TYPE_DATA)
                        msg_buf.write_int16(DUMP_HEADER_BLOCK_ID)
                        msg_buf.write_len_prefixed_bytes(
                            block.schema_object_id.bytes)
                        msg_buf.write_int16(DUMP_HEADER_BLOCK_NUM)
                        msg_buf.write_len_prefixed_bytes(
                            str(block_num).encode())
                        msg_buf.write_int16(DUMP_HEADER_BLOCK_DATA)
                        msg_buf.write_len_prefixed_buffer(data)

                        self._transport.write(memoryview(msg_buf.end_message()))
                        if self._write_waiter:
                            await self._write_waiter

            await pgcon.sql_execute(b"ROLLBACK;")

        finally:
            self._in_dump_restore = False
            tenant.release_pgcon(dbname, pgcon)

        msg_buf = WriteBuffer.new_message(b'C')
        msg_buf.write_int16(0)  # no headers
        msg_buf.write_int64(0)  # capabilities
        msg_buf.write_len_prefixed_bytes(b'DUMP')
        msg_buf.write_bytes(sertypes.NULL_TYPE_ID.bytes)
        msg_buf.write_len_prefixed_bytes(b'')
        self.write(msg_buf.end_message())
        self.flush()

    async def _execute_utility_stmt(self, eql: str, pgcon):
        cdef dbview.DatabaseConnectionView _dbview

        query_req = dbview.QueryRequestInfo(edgeql.Source.from_string(eql),
                                            self.protocol_version)

        _dbview = self.get_dbview()

        compiled = await _dbview.parse(query_req)
        query_unit_group = compiled.query_unit_group
        assert len(query_unit_group) == 1
        query_unit = query_unit_group[0]

        try:
            _dbview.start(query_unit)
            await pgcon.sql_execute(query_unit.sql)
        except Exception:
            _dbview.on_error()
            if (
                query_unit.tx_commit and
                not pgcon.in_tx() and
                _dbview.in_tx()
            ):
                # The COMMIT command has failed. Our Postgres connection
                # isn't in a transaction anymore. Abort the transaction
                # in dbview.
                _dbview.abort_tx()
            raise
        else:
            _dbview.on_success(query_unit, {})
            # _execute_utility_stmt is only used in restore(), where the state
            # serializer is not coming with the COMMIT command. However, we try
            # to keep the state serializer here anyways in case of future use
            if query_unit_group.state_serializer is not None:
                _dbview.set_state_serializer(query_unit_group.state_serializer)

    async def restore(self):
        cdef:
            WriteBuffer msg_buf
            char mtype
            dbview.DatabaseConnectionView _dbview

        _dbview = self.get_dbview()
        if _dbview.txid:
            raise errors.ProtocolError(
                'RESTORE must not be executed while in transaction'
            )
        if _dbview.get_state_serializer() is None:
            await _dbview.reload_state_serializer()

        self.reject_headers()
        self.buffer.read_int16()  # discard -j level

        # Now parse the embedded dump header message:

        server = self.server
        compiler_pool = server.get_compiler_pool()

        global_schema_pickle = _dbview.get_global_schema_pickle()
        user_schema_pickle = _dbview.get_user_schema_pickle()

        dump_server_ver_str = None
        cat_ver = None
        headers_num = self.buffer.read_int16()
        for _ in range(headers_num):
            hdrname = self.buffer.read_int16()
            hdrval = self.buffer.read_len_prefixed_bytes()
            if hdrname == DUMP_HEADER_SERVER_VER:
                dump_server_ver_str = hdrval.decode('utf-8')
            if hdrname == DUMP_HEADER_SERVER_CATALOG_VERSION:
                cat_ver = parse_catalog_version_header(hdrval)

        proto_major = self.buffer.read_int16()
        proto_minor = self.buffer.read_int16()
        proto = (proto_major, proto_minor)
        if proto > DUMP_VER_MAX or proto < DUMP_VER_MIN:
            raise errors.ProtocolError(
                f'unsupported dump version {proto_major}.{proto_minor}')

        schema_ddl = self.buffer.read_len_prefixed_bytes()

        ids_num = self.buffer.read_int32()
        schema_ids = []
        for _ in range(ids_num):
            schema_ids.append((
                self.buffer.read_len_prefixed_utf8(),
                self.buffer.read_len_prefixed_utf8(),
                self.buffer.read_bytes(16),
            ))

        block_num = <uint32_t>self.buffer.read_int32()
        blocks = []
        for _ in range(block_num):
            blocks.append((
                self.buffer.read_bytes(16),
                self.buffer.read_len_prefixed_bytes(),
            ))

            # Ignore deps info
            for _ in range(self.buffer.read_int16()):
                self.buffer.read_bytes(16)

        self.buffer.finish_message()
        dbname = _dbview.dbname
        tenant = self.tenant
        pgcon = await tenant.acquire_pgcon(dbname)

        self._in_dump_restore = True
        try:
            _dbview.decode_state(sertypes.NULL_TYPE_ID.bytes, b'')
            await self._execute_utility_stmt(
                'START TRANSACTION ISOLATION SERIALIZABLE',
                pgcon,
            )

            await pgcon.sql_execute(
                b'''
                    -- Disable transaction or query execution timeout
                    -- limits. Both clients and the server can be slow
                    -- during the dump/restore process.
                    SET LOCAL idle_in_transaction_session_timeout = 0;
                    SET LOCAL statement_timeout = 0;
                ''',
            )

            schema_sql_units, restore_blocks, tables = \
                await compiler_pool.describe_database_restore(
                    user_schema_pickle,
                    global_schema_pickle,
                    dump_server_ver_str,
                    cat_ver,
                    schema_ddl,
                    schema_ids,
                    blocks,
                    proto,
                )

            for query_unit in schema_sql_units:
                new_types = None
                _dbview.start(query_unit)

                try:
                    if query_unit.config_ops:
                        for op in query_unit.config_ops:
                            if op.scope is config.ConfigScope.INSTANCE:
                                raise errors.ProtocolError(
                                    'CONFIGURE INSTANCE cannot be executed'
                                    ' in dump restore'
                                )

                    if query_unit.sql:
                        if query_unit.ddl_stmt_id:
                            ddl_ret = await pgcon.run_ddl(query_unit)
                            if ddl_ret and ddl_ret['new_types']:
                                new_types = ddl_ret['new_types']
                        else:
                            await pgcon.sql_execute(query_unit.sql)
                except Exception:
                    _dbview.on_error()
                    raise
                else:
                    _dbview.on_success(query_unit, new_types)

            restore_blocks = {
                b.schema_object_id: b
                for b in restore_blocks
            }

            disable_trigger_q = ''
            enable_trigger_q = ''
            for table in tables:
                disable_trigger_q += (
                    f'ALTER TABLE {table} DISABLE TRIGGER ALL;'
                )
                enable_trigger_q += (
                    f'ALTER TABLE {table} ENABLE TRIGGER ALL;'
                )

            await pgcon.sql_execute(disable_trigger_q.encode())

            # Send "RestoreReadyMessage"
            msg = WriteBuffer.new_message(b'+')
            msg.write_int16(0)  # no headers
            msg.write_int16(1)  # -j1
            self.write(msg.end_message())
            self.flush()

            while True:
                if not self.buffer.take_message():
                    # Don't report idling when restoring a dump.
                    # This is an edge case and the client might be
                    # legitimately slow.
                    await self.wait_for_message(report_idling=False)
                mtype = self.buffer.get_message_type()

                if mtype == b'=':
                    block_type = None
                    block_id = None
                    block_num = None
                    block_data = None

                    num_headers = self.buffer.read_int16()
                    for _ in range(num_headers):
                        header = self.buffer.read_int16()
                        if header == DUMP_HEADER_BLOCK_TYPE:
                            block_type = self.buffer.read_len_prefixed_bytes()
                        elif header == DUMP_HEADER_BLOCK_ID:
                            block_id = self.buffer.read_len_prefixed_bytes()
                            block_id = pg_UUID(block_id)
                        elif header == DUMP_HEADER_BLOCK_NUM:
                            block_num = self.buffer.read_len_prefixed_bytes()
                        elif header == DUMP_HEADER_BLOCK_DATA:
                            block_data = self.buffer.read_len_prefixed_bytes()

                    self.buffer.finish_message()

                    if (block_type is None or block_id is None
                            or block_num is None or block_data is None):
                        raise errors.ProtocolError('incomplete data block')

                    restore_block = restore_blocks[block_id]
                    type_id_map = self._build_type_id_map_for_restore_mending(
                        restore_block)
                    self._transport.pause_reading()
                    await pgcon.restore(restore_block, block_data, type_id_map)
                    self._transport.resume_reading()

                elif mtype == b'.':
                    self.buffer.finish_message()
                    break

                else:
                    self.fallthrough()

            await pgcon.sql_execute(enable_trigger_q.encode())

        except Exception:
            await pgcon.sql_execute(b'ROLLBACK')
            _dbview.abort_tx()
            raise

        else:
            await self._execute_utility_stmt('COMMIT', pgcon)

        finally:
            self._transport.resume_reading()
            self._in_dump_restore = False
            tenant.release_pgcon(dbname, pgcon)

        execute.signal_side_effects(_dbview, dbview.SideEffects.SchemaChanges)
        await tenant.introspect_db(dbname)

        if _dbview.is_state_desc_changed():
            self.write(self.make_state_data_description_msg())

        state_tid, state_data = _dbview.encode_state()

        msg = WriteBuffer.new_message(b'C')
        msg.write_int16(0)  # no headers
        msg.write_int64(0)  # capabilities
        msg.write_len_prefixed_bytes(b'RESTORE')
        msg.write_bytes(state_tid.bytes)
        msg.write_len_prefixed_bytes(state_data)
        self.write(msg.end_message())
        self.flush()

    def _build_type_id_map_for_restore_mending(self, restore_block):
        type_map = {}
        descriptor_stack = []

        if not restore_block.data_mending_desc:
            return type_map

        descriptor_stack.append(restore_block.data_mending_desc)
        while descriptor_stack:
            desc_tuple = descriptor_stack.pop()
            for desc in desc_tuple:
                if desc is not None:
                    type_map[desc.schema_type_id] = (
                        self.get_dbview().resolve_backend_type_id(
                            desc.schema_type_id,
                        )
                    )

                    descriptor_stack.append(desc.elements)

        return type_map


@cython.final
cdef class VirtualTransport:
    def __init__(self):
        self.buf = WriteBuffer.new()
        self.closed = False

    def write(self, data):
        self.buf.write_bytes(bytes(data))

    def _get_data(self):
        return bytes(self.buf)

    def is_closing(self):
        return self.closed

    def close(self):
        self.closed = True

    def abort(self):
        self.closed = True


async def eval_buffer(
    server,
    tenant,
    database: str,
    data: bytes,
    conn_params: dict[str, str],
    protocol_version: edbdef.ProtocolVersion,
    auth_data: bytes,
    transport: srvargs.ServerConnTransport,
):
    cdef:
        VirtualTransport vtr
        EdgeConnection proto

    vtr = VirtualTransport()

    proto = new_edge_connection(
        server,
        tenant,
        passive=True,
        auth_data=auth_data,
        transport=transport,
        conn_params=conn_params,
        protocol_version=protocol_version,
    )

    proto.connection_made(vtr)
    if vtr.is_closing() or proto._main_task is None:
        raise RuntimeError(
            'cannot process the request, the server is shutting down')

    try:
        await proto._start_connection(database)
        proto.data_received(data)
        await proto._main_task
    except Exception as ex:
        proto.connection_lost(ex)
    else:
        proto.connection_lost(None)

    data = vtr._get_data()
    return data


def new_edge_connection(
    server,
    tenant,
    *,
    external_auth: bool = False,
    passive: bool = False,
    transport: srvargs.ServerConnTransport = (
        srvargs.ServerConnTransport.TCP),
    auth_data: bytes = b'',
    protocol_version: edbdef.ProtocolVersion = edbdef.CURRENT_PROTOCOL,
    conn_params: dict[str, str] | None = None,
):
    return EdgeConnection(
        server,
        tenant,
        external_auth=external_auth,
        passive=passive,
        transport=transport,
        auth_data=auth_data,
        protocol_version=protocol_version,
        conn_params=conn_params,
    )


async def run_script(
    server,
    tenant,
    database: str,
    user: str,
    script: str,
) -> None:
    cdef:
        EdgeConnection conn
        dbview.CompiledQuery compiled
    conn = new_edge_connection(server, tenant)
    await conn._start_connection(database)
    try:
        compiled = await conn.get_dbview().parse(
            dbview.QueryRequestInfo(
                edgeql.Source.from_string(script),
                conn.protocol_version,
                output_format=FMT_NONE,
            )
        )
        if len(compiled.query_unit_group) > 1:
            await conn._execute_script(compiled, b'')
        else:
            await conn._execute(compiled, b'', use_prep_stmt=0)
    except Exception as e:
        exc = await conn.interpret_error(e)
        if isinstance(exc, errors.EdgeDBError):
            raise exc from None
        else:
            raise exc
    finally:
        conn.close()
