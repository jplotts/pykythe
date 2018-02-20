"""Representation of nodes, for further processing.

ast_raw.cvt traverses an AST (in the lib2to3.pytree format) and puts
it into a more easy to process form. While traversing, it also marks
binding and non-biding uses of all the namnes (including handling of
names that were marked "global" or "nonlocal").

Each node is a subclass of AstNode.
"""

import collections
import logging  # pylint: disable=unused-import
from lib2to3 import pytree
from typing import Any, Dict, Iterator, List, Optional, Sequence, Text, TypeVar, Union
import typing

from . import kythe, pod, typing_debug

# pylint: disable=too-few-public-methods
# pylint: disable-msg=too-many-arguments
# pylint: disable=too-many-lines


class FqnCtx(pod.PlainOldData):
    """Context for computing FQNs (fully qualified names).

    Attributes:
      fqn_dot: The Fully Qualifed Name of this scope
           (module/function/class), followed by a '.'
      bindings: mappings of names to FQNs at this scope
      python_version: 2 or 3

    """

    __slots__ = ('fqn_dot', 'bindings', 'python_version')

    def __init__(self, *, fqn_dot: Text, bindings: typing.ChainMap[Text, Text],
                 python_version: int) -> None:
        # pylint: disable=super-init-not-called
        self.fqn_dot = fqn_dot
        self.bindings = bindings
        self.python_version = python_version


class AstNode(pod.PlainOldData):
    """Base class for data from AST nodes.

    These correspond to nodes in lib2to3.pytree.{Node,Leaf}.

    Each node is intended to be non-mutable (there is no code for
    enforcing this, however).

    This node should not be called directly.
    """

    # TODO: https://github.com/python/mypy/issues/4547
    __slots__ = ()  # type: Sequence[str]

    def __init__(self, **kwargs: Any) -> None:
        # pylint: disable=super-init-not-called
        # pylint: disable=unidiomatic-typecheck
        assert type(self) is not AstNode, "Must not instantiate AstNode"
        for key, value in kwargs.items():
            setattr(self, key, value)

    def as_json_dict(self) -> Dict[Text, Any]:
        """Recursively turn a node into a dict for JSON-ification."""
        result = collections.OrderedDict()  # type: Dict[Text, Any]
        for k in self.__slots__:
            value = getattr(self, k)
            if value is not None:
                result[k] = _as_json_dict_full(value)
        return {'type': self.__class__.__name__, 'slots': result}

    def fqns(self, ctx: FqnCtx) -> 'AstNode':
        """Make a new node with FQN information.

        The fully qualfied name (FQN) is a corpus-wide unique name for
        each "anchor" that gets a Kythe `ref` or `defines/binding`
        node. The FQN is a set of names separated by '.' that gives
        the name hierarchy. For examples, see the tests.

        This assumes that all subnodes of type NameNode have had the
        `binds` attribute set properly (ast_raw.cvt does this when
        creating each AstNode).

        Arguments:
          ctx: The context for generating the FQN information
               (mainly, the FQN of the enclosing scope).

        Returns:
          The same node, but with FQN information. See GenericNode for
          the canonical implementation.  A few nodes are special, such
          as FuncDefStmt and NameNode.
        """
        raise NotImplementedError(self)

    def anchors(self) -> Iterator[kythe.Anchor]:
        """Generate "anchor" nodes for Kythe facts.

        A Kythe "anchor" is a pointer to a piece of source code
        (typically, a "name" of some kind in Python) to which semantic
        information is attached. See GenericNode for the canonical
        implementation.  A few nodes are special, such as FuncDefStmt
        and NameNode.
        """
        raise NotImplementedError(self)


class AstListNode(AstNode):
    """A convenience class for AST nodes that are a simple list."""

    __slots__ = ('items', )

    def __init__(self, *, items: Sequence[AstNode]) -> None:
        # pylint: disable=super-init-not-called
        self.items = items

    _SelfType = TypeVar('_SelfType', bound='AstListNode')

    def fqns(self: _SelfType, ctx: FqnCtx) -> _SelfType:  # pylint: disable=undefined-variable
        return self._replace(items=[item.fqns(ctx) for item in self.items])

    def anchors(self) -> Iterator[kythe.Anchor]:
        for item in self.items:
            yield from item.anchors()


def _as_json_dict_full(value: Any) -> Any:
    """Recursively turn an object into a dict for JSON-ification."""
    # pylint: disable=too-many-return-statements
    if isinstance(value, pod.PlainOldData):
        return value.as_json_dict()
    if isinstance(value, list):
        return [_as_json_dict_full(v) for v in value]
    if isinstance(value, pytree.Leaf):
        return {
            'type': 'Leaf',
            'leaf_type': value.type,
            'value': value.value,
            'prefix': value.prefix,
            'lineno': value.lineno,
            'column': value.column
        }
    if isinstance(value, bool):
        return {'type': 'bool', 'value': str(value)},
    if isinstance(value, int):
        return {'type': 'int', 'value': value}
    if isinstance(value, str):
        return {'type': 'str', 'value': value},
    if isinstance(value, dict):
        return {
            'type': 'dict',
            'items': {k: _as_json_dict_full(v)
                      for k, v in value.items()}
        }
    if value is None:
        return {'type': 'None'}
    return {'NOT-POD': value.__class__.__name__, 'value': value}


class GenericNode(AstListNode):
    """An AST node that doesn't have any particular meaning.

    Some nodes are special, for example a function definition, which
    starts a new scope, or a name, which will produce either a
    `defines/binding` or `ref` Kythe fact. But many nodes have no
    particular meaning for generating Kythe facts, so they go into a a
    GenericNode.
    """

    __slots__ = ('descr', 'items')

    def __init__(self, *, descr: Text, items: Sequence[AstNode]) -> None:
        # pylint: disable=super-init-not-called
        self.descr = descr
        self.items = items


def make_generic_node(descr: Text, items: Sequence[AstNode]) -> AstNode:
    """Create a GenericNode or use the single child.

    Arguments:
      descr: A comment for debugging that identifies the raw node used
             to create the GenericNode.
      items: The subnodes.

    Returns:
      If `items` is a single item, then returns that item; otherwise, returns
      a new GenericNode containing the subnodes (`items`.
    """
    return (items[0]
            if len(items) == 1 else GenericNode(descr=descr, items=items))


class AnnAssignNode(AstNode):
    """Corresponds to `annassign`."""

    __slots__ = ('expr', 'expr_type')

    def __init__(self, *, expr: AstNode, expr_type: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.expr = expr
        self.expr_type = expr_type

    def fqns(self, ctx: FqnCtx) -> 'AnnAssignNode':
        return AnnAssignNode(
            expr=self.expr.fqns(ctx), expr_type=self.expr_type.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.expr.anchors()
        yield from self.expr_type.anchors()


class ArgListNode(AstNode):
    """Corresponds to `arg_list`."""

    __slots__ = ('args', )

    def __init__(self, *, args: Sequence[AstNode]) -> None:
        # pylint: disable=super-init-not-called
        typing_debug.assert_all_isinstance(
            (ArgNode, DictGenListSetMakerCompForNode), args)  # TODO: remove
        self.args = typing.cast(
            Sequence[Union[ArgNode, DictGenListSetMakerCompForNode]], args)

    def fqns(self, ctx: FqnCtx) -> 'ArgListNode':
        return ArgListNode(
            args=[args_item.fqns(ctx) for args_item in self.args])

    def anchors(self) -> Iterator[kythe.Anchor]:
        for args_item in self.args:
            yield from args_item.anchors()


class ArgNode(AstNode):
    """Corresponds to `argument`."""

    __slots__ = ('name_astn', 'arg', 'comp_for')

    def __init__(self, *, name_astn: Optional[pytree.Base], arg: AstNode,
                 comp_for: AstNode) -> None:
        # pylint: disable=super-init-not-called
        assert isinstance(
            name_astn, (pytree.Leaf, type(None))), [name_astn]  # TODO: remove
        self.name_astn = name_astn  # TODO: typing.cast(Optional[pytree.Leaf], name_astn)
        self.arg = arg
        assert isinstance(
            comp_for, (CompForNode, OmittedNode)), [comp_for]  # TODO: remove
        self.comp_for = comp_for  # TODO: typing.cast(Union[CompForNode, OmittedNode], comp_for)

    def fqns(self, ctx: FqnCtx) -> 'ArgNode':
        comp_for_ctx = self.comp_for.scope_ctx(ctx)
        comp_for = self.comp_for.fqns(comp_for_ctx)
        arg = self.arg.fqns(comp_for_ctx)
        return ArgNode(
            name_astn=self.name_astn,  # TODO: match to funcdef
            arg=arg,
            comp_for=comp_for)

    def anchors(self) -> Iterator[kythe.Anchor]:
        # TODO: handle self.name_astn
        yield from self.arg.anchors()
        yield from self.comp_for.anchors()


class AsNameNode(AstNode):
    """Corresponds to `import_as_name`."""

    __slots__ = ('name', 'as_name')

    def __init__(self, *, name: AstNode, as_name: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.name = typing_debug.cast(NameNode, name)
        self.as_name = typing_debug.cast(NameNode, as_name)

    def fqns(self, ctx: FqnCtx) -> 'AsNameNode':
        return AsNameNode(
            name=self.name.fqns(ctx), as_name=self.as_name.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.name.anchors()
        yield from self.as_name.anchors()


class AtomTrailerNode(AstNode):
    """Correponds to the atom, trailer part of power."""

    __slots__ = ('atom', 'trailers')

    def __init__(self, *, atom: AstNode, trailers: Sequence[AstNode]) -> None:
        # pylint: disable=super-init-not-called
        self.atom = atom
        self.trailers = trailers

    def fqns(self, ctx: FqnCtx) -> 'AtomTrailerNode':
        return AtomTrailerNode(
            atom=self.atom.fqns(ctx),
            trailers=[
                trailers_item.fqns(ctx) for trailers_item in self.trailers
            ])

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.atom.anchors()
        for trailers_item in self.trailers:
            yield from trailers_item.anchors()


class AugAssignNode(AstNode):
    """Corresponds to `augassign`."""

    __slots__ = ('op_astn', )

    def __init__(self, *, op_astn: pytree.Base) -> None:
        # pylint: disable=super-init-not-called
        self.op_astn = typing_debug.cast(pytree.Leaf, op_astn)

    def fqns(self, ctx: FqnCtx) -> 'AugAssignNode':
        return self

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from []


class ClassDefStmt(AstNode):
    """Corresponds to `classdef`."""

    __slots__ = ('name', 'bases', 'suite', 'scope_bindings')

    def __init__(self, *, name: AstNode, bases: AstNode, suite: AstNode,
                 scope_bindings: Dict[Text, None]) -> None:
        # pylint: disable=super-init-not-called
        self.name = typing_debug.cast(NameNode, name)
        assert isinstance(bases, (ArgListNode, OmittedNode))  # TODO: remove
        self.bases = bases  # TODO: typing.cast(Union[ArgListNode, OmittedNode], bases)
        self.suite = suite
        self.scope_bindings = scope_bindings

    def fqns(self, ctx: FqnCtx) -> 'ClassDefStmt':
        class_fqn = ctx.fqn_dot + self.name.astn.value
        class_ctx = ctx._replace(
            fqn_dot=class_fqn + '.',
            bindings=ctx.bindings.new_child(
                collections.OrderedDict((name, class_fqn + '.' + name)
                                        for name in self.scope_bindings)))
        return ClassDefStmt(
            name=self.name.fqns(ctx),
            bases=self.bases.fqns(ctx),
            suite=self.suite.fqns(class_ctx),
            scope_bindings=self.scope_bindings)

    def anchors(self) -> Iterator[kythe.Anchor]:
        # TODO: add bases to ClassDefAnchor
        assert self.name.binds
        assert self.name.fqn
        yield kythe.ClassDefAnchor(astn=self.name.astn, fqn=self.name.fqn)
        yield from self.bases.anchors()
        yield from self.suite.anchors()


class CompIfCompIterNode(AstNode):
    """Corresponds to `comp_if` with `comp_iter`."""

    __slots__ = ('value_expr', 'comp_iter')

    def __init__(self, *, value_expr: AstNode, comp_iter: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.value_expr = value_expr
        self.comp_iter = comp_iter

    def fqns(self, ctx: FqnCtx) -> 'CompIfCompIterNode':
        comp_iter = self.comp_iter.fqns(ctx)
        value_expr = self.value_expr.fqns(ctx)
        return CompIfCompIterNode(value_expr=value_expr, comp_iter=comp_iter)

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.value_expr.anchors()
        yield from self.comp_iter.anchors()


class CompForNode(AstNode):
    """Corresponds to `comp_for`."""

    __slots__ = ('astn', 'for_exprlist', 'in_testlist', 'comp_iter',
                 'scope_bindings')

    def __init__(self, *, astn: pytree.Base, for_exprlist: AstNode,
                 in_testlist: AstNode, comp_iter: AstNode,
                 scope_bindings: Dict[Text, None]) -> None:
        # pylint: disable=super-init-not-called
        self.astn = typing_debug.cast(pytree.Leaf, astn)
        self.for_exprlist = for_exprlist
        self.in_testlist = in_testlist
        self.comp_iter = comp_iter
        self.scope_bindings = scope_bindings

    def scope_ctx(self, ctx: FqnCtx) -> FqnCtx:
        """New FqnCtx for the scope of the comp_for (updates ctx for Python2)."""
        if ctx.python_version == 2:
            # The bindings "leak" in Python2
            ctx.bindings.update(
                (name, ctx.fqn_dot + name) for name in self.scope_bindings)
            return ctx
        for_fqn_dot = '{}<comp_for>[{:d},{:d}].'.format(
            ctx.fqn_dot, self.astn.lineno, self.astn.column)
        return ctx._replace(
            fqn_dot=for_fqn_dot,
            bindings=ctx.bindings.new_child(collections.OrderedDict()))

    def fqns(self, ctx: FqnCtx) -> 'CompForNode':
        # Assume that the caller has created a new child in the
        # bindings, if needed.  This is done at the outermost level of
        # a comp_for (for Python 3), but not for any of the inner
        # comp_for's.
        # This handles the following:
        #    x for x in [1,x]  # `x` in `[1,x]` is outer scope
        #    (x, y) for x in [1,2] for y in range(x)  # `x` in `range(x)` is from `for x`
        # [(x, y) for x in [1,2,x] for y in range(x)]  # error: y undefined
        in_testlist = self.in_testlist.fqns(ctx)
        ctx.bindings.update(
            (name, ctx.fqn_dot + name) for name in self.scope_bindings)
        for_exprlist = self.for_exprlist.fqns(ctx)
        comp_iter = self.comp_iter.fqns(ctx)
        return CompForNode(
            astn=self.astn,
            for_exprlist=for_exprlist,
            in_testlist=in_testlist,
            comp_iter=comp_iter,
            scope_bindings=self.scope_bindings)

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.for_exprlist.anchors()
        yield from self.in_testlist.anchors()
        yield from self.comp_iter.anchors()


class CompOpNode(AstNode):
    """Corresponds to `comp_op`."""

    __slots__ = ('op_astns', )

    def __init__(self, *,
                 op_astns: Sequence[Union[pytree.Node, pytree.Leaf]]) -> None:
        # pylint: disable=super-init-not-called
        self.op_astns = op_astns

    def fqns(self, ctx: FqnCtx) -> 'CompOpNode':
        return self

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from []


class ComparisonOpNode(AstNode):
    """Corresponds to `comparison_op`."""

    __slots__ = ('op', 'args')

    def __init__(self, *, op: AstNode, args: Sequence[AstNode]) -> None:
        # pylint: disable=super-init-not-called,invalid-name
        self.op = typing_debug.cast(CompOpNode, op)
        self.args = args

    def fqns(self, ctx: FqnCtx) -> 'ComparisonOpNode':
        return ComparisonOpNode(
            op=self.op, args=[args_item.fqns(ctx) for args_item in self.args])

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.op.anchors()
        for args_item in self.args:
            yield from args_item.anchors()


class DecoratorNode(AstNode):
    """Corresponds to `decorator`."""

    __slots__ = ('name', 'arglist')

    def __init__(self, *, name: AstNode, arglist: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.name = typing_debug.cast(DottedNameNode, name)
        self.arglist = arglist

    def fqns(self, ctx: FqnCtx) -> 'DecoratorNode':
        return DecoratorNode(
            name=self.name.fqns(ctx), arglist=self.arglist.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.name.anchors()
        yield from self.arglist.anchors()


class DelStmt(AstNode):
    """Corresponds to `del_stmt`."""

    __slots__ = ('exprs', )

    def __init__(self, *, exprs: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.exprs = exprs

    def fqns(self, ctx: FqnCtx) -> 'DelStmt':
        return DelStmt(exprs=self.exprs.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.exprs.anchors()


class DictSetMakerNode(AstListNode):
    """Corresponds to `dictsetmaker` without `comp_for`."""


class DictGenListSetMakerCompForNode(AstNode):
    """Corresponds to {`dict_set_maker', `listmaker`, testlist_gexp`} with
    `comp_for`. For our purposes, it's not important to know whether
    this is a list, set, or dict comprehension
    """

    __slots__ = ('value_expr', 'comp_for')

    def __init__(self, *, value_expr: AstNode, comp_for: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.value_expr = value_expr
        self.comp_for = typing_debug.cast(CompForNode, comp_for)

    def fqns(self, ctx: FqnCtx) -> 'DictGenListSetMakerCompForNode':
        comp_for_ctx = self.comp_for.scope_ctx(ctx)
        comp_for = self.comp_for.fqns(comp_for_ctx)
        value_expr = self.value_expr.fqns(comp_for_ctx)
        return DictGenListSetMakerCompForNode(
            value_expr=value_expr, comp_for=comp_for)

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.value_expr.anchors()
        yield from self.comp_for.anchors()


class DotNode(AstNode):
    """Corresponds to a DOT in `import_from`."""

    __slots__ = ()

    def __init__(self) -> None:
        # pylint: disable=super-init-not-called
        pass

    def fqns(self, ctx: FqnCtx) -> 'DotNode':
        return self

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from []


class DotNameTrailerNode(AstNode):
    """Corresponds to '.' NAME in trailer."""

    __slots__ = ('name', )

    def __init__(self, *, name: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.name = typing_debug.cast(NameNode, name)

    def fqns(self, ctx: FqnCtx) -> 'DotNameTrailerNode':
        return DotNameTrailerNode(name=self.name.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.name.anchors()


class DottedAsNameNode(AstNode):
    """Corresponds to `dotted_as_name`."""

    __slots__ = ('dotted_name', 'as_name')

    def __init__(self, *, dotted_name: AstNode, as_name: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.dotted_name = typing_debug.cast(DottedNameNode, dotted_name)
        self.as_name = typing_debug.cast(NameNode, as_name)

    def fqns(self, ctx: FqnCtx) -> 'DottedAsNameNode':
        return DottedAsNameNode(
            dotted_name=self.dotted_name.fqns(ctx),
            as_name=self.as_name.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.dotted_name.anchors()
        yield from self.as_name.anchors()


class DottedAsNamesNode(AstNode):
    """Corresponds to `dotted_as_names`."""

    __slots__ = ('names', )

    def __init__(self, *, names: Sequence[AstNode]) -> None:
        # pylint: disable=super-init-not-called
        typing_debug.assert_all_isinstance(DottedAsNameNode,
                                           names)  # TODO: remove
        self.names = typing.cast(Sequence[DottedAsNameNode], names)

    def fqns(self, ctx: FqnCtx) -> 'DottedAsNamesNode':
        return DottedAsNamesNode(
            names=[names_item.fqns(ctx) for names_item in self.names])

    def anchors(self) -> Iterator[kythe.Anchor]:
        for names_item in self.names:
            yield from names_item.anchors()


class DottedNameNode(AstNode):
    """Corresponds to `dotted_name`."""

    __slots__ = ('names', )

    def __init__(self, *, names: Sequence[AstNode]) -> None:
        # pylint: disable=super-init-not-called
        typing_debug.assert_all_isinstance(NameNode, names)  # TODO: remove
        self.names = typing.cast(Sequence[NameNode], names)

    def fqns(self, ctx: FqnCtx) -> 'DottedNameNode':
        return DottedNameNode(
            names=[names_item.fqns(ctx) for names_item in self.names])

    def anchors(self) -> Iterator[kythe.Anchor]:
        for names_item in self.names:
            yield from names_item.anchors()


class ExprListNode(AstNode):
    """Corresponds to `explist`."""

    __slots__ = ('exprs', )

    def __init__(self, *, exprs: Sequence[AstNode]) -> None:
        # pylint: disable=super-init-not-called
        self.exprs = exprs

    def fqns(self, ctx: FqnCtx) -> 'ExprListNode':
        return ExprListNode(
            exprs=[exprs_item.fqns(ctx) for exprs_item in self.exprs])

    def anchors(self) -> Iterator[kythe.Anchor]:
        for exprs_item in self.exprs:
            yield from exprs_item.anchors()


class ExceptClauseNode(AstNode):
    """Corresponds to `except_clause`."""

    __slots__ = ('expr', 'as_item')

    def __init__(self, *, expr: AstNode, as_item: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.expr = expr
        self.as_item = as_item

    def fqns(self, ctx: FqnCtx) -> 'ExceptClauseNode':
        return ExceptClauseNode(
            expr=self.expr.fqns(ctx), as_item=self.as_item.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.expr.anchors()
        yield from self.as_item.anchors()


class ExprStmt(AstNode):
    """Corresponds to `expr_stmt`."""

    __slots__ = ('lhs', 'augassign', 'exprs')

    def __init__(self, *, lhs: AstNode, augassign: AstNode,
                 exprs: Sequence[AstNode]) -> None:
        # pylint: disable=super-init-not-called
        self.lhs = lhs
        assert isinstance(augassign,
                          (AugAssignNode, OmittedNode))  # TODO: remove
        # TODO: self.augassign = typing.cast(Union[AugAssignNode, OmittedNode], augassign)
        self.augassign = augassign
        self.exprs = exprs

    def fqns(self, ctx: FqnCtx) -> 'ExprStmt':
        return ExprStmt(
            lhs=self.lhs.fqns(ctx),
            augassign=self.augassign.fqns(ctx),
            exprs=[exprs_item.fqns(ctx) for exprs_item in self.exprs])

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.lhs.anchors()
        yield from self.augassign.anchors()
        for exprs_item in self.exprs:
            yield from exprs_item.anchors()


class FileInput(AstNode):
    """Corresponds to `file_input`."""

    __slots__ = ('stmts', 'scope_bindings')

    def __init__(self, *, stmts: Sequence[AstNode],
                 scope_bindings: Dict[Text, None]) -> None:
        # pylint: disable=super-init-not-called
        self.stmts = stmts
        self.scope_bindings = scope_bindings

    def fqns(self, ctx: FqnCtx) -> 'FileInput':
        file_ctx = ctx._replace(
            bindings=ctx.bindings.new_child(
                collections.OrderedDict((name, ctx.fqn_dot + name)
                                        for name in self.scope_bindings)))
        return FileInput(
            stmts=[stmt.fqns(file_ctx) for stmt in self.stmts],
            scope_bindings=self.scope_bindings)

    def anchors(self) -> Iterator[kythe.Anchor]:
        for stmt in self.stmts:
            yield from stmt.anchors()


class ForStmt(AstNode):
    """Corresponds to `for_stmt`."""

    __slots__ = ('exprlist', 'testlist', 'suite', 'else_suite')

    def __init__(self, *, exprlist: AstNode, testlist: AstNode, suite: AstNode,
                 else_suite: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.exprlist = exprlist
        self.testlist = testlist
        self.suite = suite
        self.else_suite = else_suite

    def fqns(self, ctx: FqnCtx) -> 'ForStmt':
        # TODO: Add self.exprlist's bindings to suite and "leak" to
        #       outer context.  See also CompForNode.fqns
        return ForStmt(
            exprlist=self.exprlist.fqns(ctx),
            testlist=self.testlist.fqns(ctx),
            suite=self.suite.fqns(ctx),
            else_suite=self.else_suite.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.exprlist.anchors()
        yield from self.testlist.anchors()
        yield from self.suite.anchors()
        yield from self.else_suite.anchors()


class FuncDefStmt(AstNode):
    """Corresponds to `funcdef` / `async_funcdef` or lambdadef.

    If it's a lambda, the `name` points to the `lambda` keyword.
    """

    __slots__ = ('name', 'parameters', 'return_type', 'suite',
                 'scope_bindings')

    def __init__(self, *, name: 'NameNode', parameters: Sequence[AstNode],
                 return_type: AstNode, suite: AstNode,
                 scope_bindings: Dict[Text, None]) -> None:
        # pylint: disable=super-init-not-called
        self.name = name
        self.parameters = parameters
        self.return_type = return_type
        self.suite = suite
        self.scope_bindings = scope_bindings

    def fqns(self, ctx: FqnCtx) -> 'FuncDefStmt':
        # '.<local>.' is needed to distinguish `x` in following:
        #    def foo(x): pass
        #    foo.x = 'a string'
        if self.name.astn.value == 'lambda':
            # Make a unique name for the lambda
            func_fqn_dot = '{}<lambda>[{:d},{:d}].<local>.'.format(
                ctx.fqn_dot, self.name.astn.lineno, self.name.astn.column)
        else:
            func_fqn_dot = '{}{}.<local>.'.format(ctx.fqn_dot,
                                                  self.name.astn.value)
        func_ctx = ctx._replace(
            fqn_dot=func_fqn_dot,
            bindings=ctx.bindings.new_child(
                collections.OrderedDict((name, func_fqn_dot + name)
                                        for name in self.scope_bindings)))
        return FuncDefStmt(
            name=self.name.fqns(ctx),
            parameters=[p.fqns(func_ctx) for p in self.parameters],
            return_type=self.return_type.fqns(ctx),
            suite=self.suite.fqns(func_ctx),
            scope_bindings=self.scope_bindings)

    def anchors(self) -> Iterator[kythe.Anchor]:
        assert self.name.binds
        assert self.name.fqn
        yield kythe.FuncDefAnchor(astn=self.name.astn, fqn=self.name.fqn)
        for parameter in self.parameters:
            yield from parameter.anchors()
        yield from self.return_type.anchors()
        yield from self.suite.anchors()


class GlobalStmt(AstNode):
    """Corresponds to `global_stmt`."""

    __slots__ = ('names', )

    def __init__(self, *, names: Sequence[AstNode]) -> None:
        # pylint: disable=super-init-not-called
        typing_debug.assert_all_isinstance(NameNode, names)  # TODO: remove
        self.names = typing.cast(Sequence[NameNode], names)

    def fqns(self, ctx: FqnCtx) -> 'GlobalStmt':
        return GlobalStmt(
            names=[names_item.fqns(ctx) for names_item in self.names])

    def anchors(self) -> Iterator[kythe.Anchor]:
        for names_item in self.names:
            yield from names_item.anchors()


class ImportAsNamesNode(AstNode):
    """Corresponds to `import_as_names`."""

    __slots__ = ('names', )

    def __init__(self, *, names: Sequence[AstNode]) -> None:
        # pylint: disable=super-init-not-called
        typing_debug.assert_all_isinstance(AsNameNode, names)  # TODO: remove
        self.names = typing.cast(Sequence[AsNameNode], names)

    def fqns(self, ctx: FqnCtx) -> 'ImportAsNamesNode':
        return ImportAsNamesNode(
            names=[names_item.fqns(ctx) for names_item in self.names])

    def anchors(self) -> Iterator[kythe.Anchor]:
        for names_item in self.names:
            yield from names_item.anchors()


class ImportFromStmt(AstNode):
    """Corresponds to `import_name`."""

    __slots__ = ('from_name', 'import_part')

    def __init__(self, *, from_name: Sequence[AstNode],
                 import_part: AstNode) -> None:
        # pylint: disable=super-init-not-called
        typing_debug.assert_all_isinstance(DottedNameNode,
                                           from_name)  # TODO: remove
        self.from_name = typing.cast(Sequence[DottedNameNode], from_name)
        assert isinstance(import_part,
                          (ImportAsNamesNode, StarNode))  # TODO: remove
        # TODO: self.import_part = typing.cast(Union[ImportAsNamesNode, StarNode], import_part)
        self.import_part = import_part

    def fqns(self, ctx: FqnCtx) -> 'ImportFromStmt':
        return ImportFromStmt(
            from_name=[
                from_name_item.fqns(ctx) for from_name_item in self.from_name
            ],
            import_part=self.import_part.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        for from_name_item in self.from_name:
            yield from from_name_item.anchors()
        yield from self.import_part.anchors()


class ImportNameNode(AstNode):
    """Corresponds to `import_name`."""

    __slots__ = ('dotted_as_names', )

    def __init__(self, *, dotted_as_names: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.dotted_as_names = typing_debug.cast(DottedAsNamesNode,
                                                 dotted_as_names)

    def fqns(self, ctx: FqnCtx) -> 'ImportNameNode':
        return ImportNameNode(dotted_as_names=self.dotted_as_names.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.dotted_as_names.anchors()


class ListMakerNode(AstListNode):
    """Corresponds to `listmaker` without `comp_for`."""


class NameNode(AstNode):
    """Corresponds to a NAME node.

    Attributes:
        binds: Whether this name is in a binding context or not.
        astn: The AST node of the name (a Leaf node) - the name
              is self.astn.value
        fqn: The Fully Qualified Name (FQN) for this name. Initially
             None; it is filled in by calling fqns() on the top node.
    """

    __slots__ = ('binds', 'astn', 'fqn')

    def __init__(self, *, binds: bool, astn: pytree.Leaf,
                 fqn: Optional[Text]) -> None:
        # pylint: disable=super-init-not-called
        self.binds = binds
        self.astn = astn
        self.fqn = fqn

    def fqns(self, ctx: FqnCtx) -> 'NameNode':
        name = self.astn.value
        if name in ctx.bindings:
            fqn = ctx.bindings[name]
        else:
            fqn = ctx.fqn_dot + self.astn.value
            ctx.bindings[name] = fqn
        return NameNode(astn=self.astn, binds=self.binds, fqn=fqn)

    def anchors(self) -> Iterator[kythe.Anchor]:
        if self.binds:
            assert self.fqn
            yield kythe.BindingAnchor(astn=self.astn, fqn=self.fqn)
        else:
            if self.fqn:
                # There are some obscure cases where self.fqn doesn't
                # get filled in, typically due to the grammar
                # accepting an illegal Python program (e.g., the
                # grammar allows test=test for an arg, but it should
                # be NAME=test)
                yield kythe.RefAnchor(astn=self.astn, fqn=self.fqn)


class NonLocalStmt(AstNode):
    """Corresponds to "nonlocal" variant of `global_stmt`."""

    __slots__ = ('names', )

    def __init__(self, *, names: Sequence[AstNode]) -> None:
        # pylint: disable=super-init-not-called
        typing_debug.assert_all_isinstance(NameNode, names)  # TODO: remove
        self.names = typing.cast(Sequence[NameNode], names)

    def fqns(self, ctx: FqnCtx) -> 'NonLocalStmt':
        return NonLocalStmt(
            names=[names_item.fqns(ctx) for names_item in self.names])

    def anchors(self) -> Iterator[kythe.Anchor]:
        for names_item in self.names:
            yield from names_item.anchors()


class NumberNode(AstNode):
    """Corresponds to a NUMBER node.

    Attributes:
    astn: The AST node of the number
    """

    __slots__ = ('astn', )

    def __init__(self, *, astn: pytree.Leaf) -> None:
        # pylint: disable=super-init-not-called
        self.astn = astn

    def fqns(self, ctx: FqnCtx) -> 'NumberNode':
        return self

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from []


class OpNode(AstNode):
    """Corresponds to various expression nodes (unary, binary)."""

    __slots__ = ('op_astn', 'args')

    def __init__(self, *, op_astn: pytree.Base,
                 args: Sequence[AstNode]) -> None:
        # pylint: disable=super-init-not-called
        self.op_astn = typing_debug.cast(pytree.Leaf, op_astn)
        self.args = args

    def fqns(self, ctx: FqnCtx) -> 'OpNode':
        return OpNode(
            op_astn=self.op_astn,
            args=[args_item.fqns(ctx) for args_item in self.args])

    def anchors(self) -> Iterator[kythe.Anchor]:
        for args_item in self.args:
            yield from args_item.anchors()


class StarExprNode(AstNode):
    """Corresponds to `star_expr`."""

    __slots__ = ('expr', )

    def __init__(self, *, expr: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.expr = expr

    def fqns(self, ctx: FqnCtx) -> 'StarExprNode':
        return StarExprNode(expr=self.expr.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.expr.anchors()


class StarStarExprNode(AstNode):
    """Corresponds to `'**' expr`."""

    __slots__ = ('expr', )

    def __init__(self, *, expr: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.expr = expr

    def fqns(self, ctx: FqnCtx) -> 'StarStarExprNode':
        return StarStarExprNode(expr=self.expr.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.expr.anchors()


class StringNode(AstNode):
    """Corresponds to a STRING node.

    Attributes:
        astns: The AST nodes of the string
    """

    __slots__ = ('astns', )

    def __init__(self, *, astns: Sequence[pytree.Leaf]) -> None:
        # pylint: disable=super-init-not-called
        self.astns = astns

    def fqns(self, ctx: FqnCtx) -> 'StringNode':
        return self

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from []


class SubscriptListNode(AstNode):
    """Corresponds to `subscript_list`."""

    __slots__ = ('subscripts', )

    def __init__(self, *, subscripts: Sequence[AstNode]) -> None:
        # pylint: disable=super-init-not-called
        typing_debug.assert_all_isinstance(SubscriptNode,
                                           subscripts)  # TODO: remove
        self.subscripts = typing.cast(Sequence[SubscriptNode], subscripts)

    def fqns(self, ctx: FqnCtx) -> 'SubscriptListNode':
        return SubscriptListNode(subscripts=[
            subscripts_item.fqns(ctx) for subscripts_item in self.subscripts
        ])

    def anchors(self) -> Iterator[kythe.Anchor]:
        for subscripts_item in self.subscripts:
            yield from subscripts_item.anchors()


class SubscriptNode(AstNode):
    """Corresponds to `subscript`."""

    __slots__ = ('expr1', 'expr2', 'expr3')

    def __init__(self, *, expr1: AstNode, expr2: AstNode,
                 expr3: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.expr1 = expr1
        self.expr2 = expr2
        self.expr3 = expr3

    def fqns(self, ctx: FqnCtx) -> 'SubscriptNode':
        return SubscriptNode(
            expr1=self.expr1.fqns(ctx),
            expr2=self.expr2.fqns(ctx),
            expr3=self.expr3.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.expr1.anchors()
        yield from self.expr2.anchors()
        yield from self.expr3.anchors()


class TestListNode(AstListNode):
    """Corresponds to `testlist`, `testlist1`, `testlist_gexp`
    `testlist_star_expr` without `comp_for`."""


class TnameNode(AstNode):
    """Corresponds to `tname`."""

    __slots__ = ('name', 'type_expr')

    def __init__(self, *, name: AstNode, type_expr: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.name = typing_debug.cast(NameNode, name)
        self.type_expr = type_expr

    def fqns(self, ctx: FqnCtx) -> 'TnameNode':
        return TnameNode(
            name=self.name.fqns(ctx), type_expr=self.type_expr.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.name.anchors()
        yield from self.type_expr.anchors()


class TfpListNode(AstListNode):
    """Corresponds to `tfplist`."""


class TypedArgNode(AstNode):
    """Corresponds to `typed_arg`."""

    __slots__ = ('name', 'expr')

    def __init__(self, *, name: AstNode, expr: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.name = typing_debug.cast(TnameNode, name)
        self.expr = expr

    def fqns(self, ctx: FqnCtx) -> 'TypedArgNode':
        return TypedArgNode(name=self.name.fqns(ctx), expr=self.expr.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.name.anchors()
        yield from self.expr.anchors()


class TypedArgsListNode(AstNode):
    """Corresponds to `typedargslist`.

    This is only used when processing a funcdef; the args are given
    directly to FuncDefStmt, which is why fqns() and anchors() aren't
    defined for TypedArgsListNode.
    """

    __slots__ = ('args', )

    def __init__(self, *, args: Sequence[TypedArgNode]) -> None:
        # pylint: disable=super-init-not-called
        self.args = args

    def fqns(self, ctx: FqnCtx) -> 'TypedArgsListNode':
        # Not used anywhere
        raise NotImplementedError(self)

    def anchors(self) -> Iterator[kythe.Anchor]:
        # Not used anywhere
        raise NotImplementedError(self)


class WithItemNode(AstNode):
    """Corresponds to `with_item`."""

    __slots__ = ('item', 'as_item')

    def __init__(self, *, item: AstNode, as_item: AstNode) -> None:
        # pylint: disable=super-init-not-called
        self.item = typing_debug.cast(AtomTrailerNode, item)
        self.as_item = as_item

    def fqns(self, ctx: FqnCtx) -> 'WithItemNode':
        return WithItemNode(
            item=self.item.fqns(ctx), as_item=self.as_item.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from self.item.anchors()
        yield from self.as_item.anchors()


class WithStmt(AstNode):
    """Corresponds to `with_stmt`."""

    __slots__ = ('items', 'suite')

    def __init__(self, *, items: Sequence[AstNode], suite: AstNode) -> None:
        # pylint: disable=super-init-not-called
        typing_debug.assert_all_isinstance(WithItemNode, items)  # TODO: remove
        self.items = typing.cast(Sequence[WithItemNode], items)
        self.suite = suite

    def fqns(self, ctx: FqnCtx) -> 'WithStmt':
        return WithStmt(
            items=[items_item.fqns(ctx) for items_item in self.items],
            suite=self.suite.fqns(ctx))

    def anchors(self) -> Iterator[kythe.Anchor]:
        for items_item in self.items:
            yield from items_item.anchors()
        yield from self.suite.anchors()


class OmittedNode(AstNode):
    """An item that is omitted (e.g., bases for a class)."""

    __slots__ = ()

    def fqns(self, ctx: FqnCtx) -> 'OmittedNode':
        return self

    def scope_ctx(self, ctx: FqnCtx) -> FqnCtx:  # pylint: disable=no-self-use
        # For nodes that can be Union[CompForNode, OmittedNode]
        return ctx

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from []


class StarNode(AstNode):
    """Corresponds to `'*' expr`."""

    __slots__ = ()

    def fqns(self, ctx: FqnCtx) -> 'StarNode':
        return self

    def anchors(self) -> Iterator[kythe.Anchor]:
        yield from []


# Singleton OmittedNode, to avoid creating many of them.
OMITTED_NODE = OmittedNode()
