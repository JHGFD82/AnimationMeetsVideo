"""Times and values as they cross to and from the app.

Times are `fractions.Fraction` seconds, exact as `project.json` keeps them
(the app sends them as [numerator, denominator]). A time given as a float
is sent as one, and the app rounds it to a frame of the timeline; a
Fraction or an int is taken exactly.
"""

import math
from fractions import Fraction
from numbers import Real


def time_in(value):
    """A time from the app: [numerator, denominator], or None."""
    if value is None:
        return None
    numerator, denominator = value
    return Fraction(numerator, denominator)


def time_out(value):
    """A time for the app."""
    if isinstance(value, bool):
        raise TypeError("A time is a number of seconds, not %r" % value)
    if isinstance(value, Fraction):
        return [value.numerator, value.denominator]
    if isinstance(value, int):
        return [value, 1]
    if isinstance(value, Real):
        value = float(value)
        if not math.isfinite(value):
            raise ValueError("A time must be a finite number of seconds, not %r" % value)
        return value
    raise TypeError("A time is a number of seconds, not %s" % type(value).__name__)


def value_in(value):
    """A control's value from the app: a number, a Vector, or a choice's
    option."""
    if isinstance(value, list):
        return Vector(value)
    return value


def value_out(value):
    """A control's value for the app: a number, a list of numbers, or a
    choice's option."""
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        raise TypeError("A control's value is a number, not %r" % value)
    if isinstance(value, Real):
        return _finite(value)
    try:
        items = list(value)
    except TypeError:
        raise TypeError("A control's value is a number or a list of numbers, not %s" % type(value).__name__) from None
    return [_finite(item) for item in items]


def _finite(number):
    if isinstance(number, bool) or not isinstance(number, Real):
        raise TypeError("A control's value is made of numbers, not %s" % type(number).__name__)
    number = float(number)
    if not math.isfinite(number):
        raise ValueError("A control's value must be finite, not %r" % number)
    return number


class Vector(tuple):
    """A value of several numbers (a position, a scale, a color), which adds,
    subtracts, multiplies and divides with numbers and with other vectors,
    component by component."""

    __slots__ = ()

    def __new__(cls, components):
        return super().__new__(cls, (float(c) for c in components))

    def _with(self, other, operation):
        if isinstance(other, Real):
            return Vector(operation(a, other) for a in self)
        other = tuple(other)
        if len(other) != len(self):
            raise ValueError("Vectors of %d and %d numbers don't combine" % (len(self), len(other)))
        return Vector(operation(a, b) for a, b in zip(self, other))

    def _from(self, other, operation):
        if isinstance(other, Real):
            return Vector(operation(other, a) for a in self)
        return Vector(other)._with(self, operation)

    def __add__(self, other):
        return self._with(other, lambda a, b: a + b)

    def __radd__(self, other):
        return self._from(other, lambda a, b: a + b)

    def __sub__(self, other):
        return self._with(other, lambda a, b: a - b)

    def __rsub__(self, other):
        return self._from(other, lambda a, b: a - b)

    def __mul__(self, other):
        return self._with(other, lambda a, b: a * b)

    def __rmul__(self, other):
        return self._from(other, lambda a, b: a * b)

    def __truediv__(self, other):
        return self._with(other, lambda a, b: a / b)

    def __rtruediv__(self, other):
        return self._from(other, lambda a, b: a / b)

    def __neg__(self):
        return Vector(-a for a in self)

    def __pos__(self):
        return self

    def __abs__(self):
        return Vector(abs(a) for a in self)

    @property
    def x(self):
        return self[0]

    @property
    def y(self):
        return self[1]

    def __repr__(self):
        return "Vector(%s)" % ", ".join(_short(a) for a in self)


def _short(number):
    return ("%.6g" % number) if number != int(number) else str(int(number))
