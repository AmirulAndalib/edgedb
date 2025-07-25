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


from __future__ import annotations
from typing import Callable, TypeVar, TYPE_CHECKING

import enum

from edb.common import enum as strenum
from edb.edgeql import qltypes as ir
from edb.protocol.enums import Cardinality as Cardinality


if TYPE_CHECKING:
    Error_T = TypeVar('Error_T')


TypeTag = ir.TypeTag


class Capability(enum.IntFlag):

    # Capability flags that are part of the protocol.
    # Can be picked up with the PROTO_CAPS mask.
    MODIFICATIONS     = 1 << 0    # noqa
    SESSION_CONFIG    = 1 << 1    # noqa
    TRANSACTION       = 1 << 2    # noqa
    DDL               = 1 << 3    # noqa
    PERSISTENT_CONFIG = 1 << 4    # noqa

    # Internal only capability flags.
    GLOBAL_DDL        = 1 << 57   # noqa
    SQL_SESSION_CONFIG= 1 << 58   # noqa
    BRANCH_CONFIG     = 1 << 59   # noqa
    INSTANCE_CONFIG   = 1 << 60   # noqa
    DESCRIBE          = 1 << 61   # noqa
    ANALYZE           = 1 << 62   # noqa
    ADMINISTER        = 1 << 63   # noqa

    PROTO_CAPS        = (1 << 32) - 1  # noqa
    ALL               = (1 << 64) - 1  # noqa
    WRITE             = (MODIFICATIONS | DDL | PERSISTENT_CONFIG)  # noqa
    NONE              = 0  # noqa

    def make_error(
        self,
        allowed: Capability,
        error_constructor: Callable[[str], Error_T],
        reason: str,
    ) -> Error_T:
        for item in Capability:
            if item & allowed:
                continue
            if self & item:
                return error_constructor(
                    f"cannot execute {CAPABILITY_TITLES[item]}: {reason}")
        raise AssertionError(
            f"extra capability not found in"
            f" {self} allowed {allowed}"
        )


CAPABILITY_TITLES = {
    Capability.MODIFICATIONS: 'data modification queries',
    Capability.SESSION_CONFIG: 'session configuration queries',
    Capability.TRANSACTION: 'transaction control commands',
    Capability.DDL: 'DDL commands',
    Capability.PERSISTENT_CONFIG: 'configuration commands',
    Capability.ADMINISTER: 'ADMINISTER commands',
    Capability.DESCRIBE: 'DESCRIBE commands',
    Capability.ANALYZE: 'ANALYZE commands',
    Capability.INSTANCE_CONFIG: 'instance configuration commands',
    Capability.BRANCH_CONFIG: 'database branch configuration commands',
    Capability.SQL_SESSION_CONFIG: 'sql session configuration commands',
    Capability.GLOBAL_DDL: 'instance-wide DDL commands',
}


class OutputFormat(strenum.StrEnum):
    BINARY = 'BINARY'
    JSON = 'JSON'
    JSON_ELEMENTS = 'JSON_ELEMENTS'
    NONE = 'NONE'


class InputFormat(strenum.StrEnum):
    BINARY = 'BINARY'
    JSON = 'JSON'


class InputLanguage(strenum.StrEnum):
    EDGEQL = 'EDGEQL'
    SQL = 'SQL'
    SQL_PARAMS = 'SQL_PARAMS'
    GRAPHQL = 'GRAPHQL'


def cardinality_from_ir_value(card: ir.Cardinality) -> Cardinality:
    if card is ir.Cardinality.AT_MOST_ONE:
        return Cardinality.AT_MOST_ONE
    elif card is ir.Cardinality.ONE:
        return Cardinality.ONE
    elif card is ir.Cardinality.MANY:
        return Cardinality.MANY
    elif card is ir.Cardinality.AT_LEAST_ONE:
        return Cardinality.AT_LEAST_ONE
    else:
        raise ValueError(
            f"Cardinality.from_ir_value() got an invalid input: {card}"
        )
