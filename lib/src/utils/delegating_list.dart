// Substitui `DelegatingList` do pacote `collection` (1.19.1), mantendo a mesma
// semântica: todas as operações são repassadas para a lista base.
//
// Copyright 2015, the Dart project authors. Use of this source code is
// governed by a BSD-style license (ver lib/src/utils/stream_channel.dart).

import 'dart:math' as math;

/// A [List] that delegates all operations to a base list.
class DelegatingList<E> implements List<E> {
  final List<E> _base;

  const DelegatingList(List<E> base) : _base = base;

  @override
  bool any(bool Function(E) test) => _base.any(test);

  @override
  List<T> cast<T>() => _base.cast<T>();

  @override
  bool contains(Object? element) => _base.contains(element);

  @override
  E elementAt(int index) => _base.elementAt(index);

  @override
  bool every(bool Function(E) test) => _base.every(test);

  @override
  Iterable<T> expand<T>(Iterable<T> Function(E) f) => _base.expand(f);

  @override
  E get first => _base.first;

  @override
  E firstWhere(bool Function(E) test, {E Function()? orElse}) =>
      _base.firstWhere(test, orElse: orElse);

  @override
  T fold<T>(T initialValue, T Function(T previousValue, E element) combine) =>
      _base.fold(initialValue, combine);

  @override
  Iterable<E> followedBy(Iterable<E> other) => _base.followedBy(other);

  @override
  void forEach(void Function(E) f) => _base.forEach(f);

  @override
  bool get isEmpty => _base.isEmpty;

  @override
  bool get isNotEmpty => _base.isNotEmpty;

  @override
  Iterator<E> get iterator => _base.iterator;

  @override
  String join([String separator = '']) => _base.join(separator);

  @override
  E get last => _base.last;

  @override
  E lastWhere(bool Function(E) test, {E Function()? orElse}) =>
      _base.lastWhere(test, orElse: orElse);

  @override
  int get length => _base.length;

  @override
  Iterable<T> map<T>(T Function(E) f) => _base.map(f);

  @override
  E reduce(E Function(E value, E element) combine) => _base.reduce(combine);

  @override
  E get single => _base.single;

  @override
  E singleWhere(bool Function(E) test, {E Function()? orElse}) {
    return _base.singleWhere(test, orElse: orElse);
  }

  @override
  Iterable<E> skip(int n) => _base.skip(n);

  @override
  Iterable<E> skipWhile(bool Function(E) test) => _base.skipWhile(test);

  @override
  Iterable<E> take(int n) => _base.take(n);

  @override
  Iterable<E> takeWhile(bool Function(E) test) => _base.takeWhile(test);

  @override
  List<E> toList({bool growable = true}) => _base.toList(growable: growable);

  @override
  Set<E> toSet() => _base.toSet();

  @override
  Iterable<E> where(bool Function(E) test) => _base.where(test);

  @override
  Iterable<T> whereType<T>() => _base.whereType<T>();

  @override
  String toString() => _base.toString();

  @override
  E operator [](int index) => _base[index];

  @override
  void operator []=(int index, E value) {
    _base[index] = value;
  }

  @override
  List<E> operator +(List<E> other) => _base + other;

  @override
  void add(E value) {
    _base.add(value);
  }

  @override
  void addAll(Iterable<E> iterable) {
    _base.addAll(iterable);
  }

  @override
  Map<int, E> asMap() => _base.asMap();

  @override
  void clear() {
    _base.clear();
  }

  @override
  void fillRange(int start, int end, [E? fillValue]) {
    _base.fillRange(start, end, fillValue);
  }

  @override
  set first(E value) {
    if (isEmpty) throw RangeError.index(0, this);
    this[0] = value;
  }

  @override
  Iterable<E> getRange(int start, int end) => _base.getRange(start, end);

  @override
  int indexOf(E element, [int start = 0]) => _base.indexOf(element, start);

  @override
  int indexWhere(bool Function(E) test, [int start = 0]) =>
      _base.indexWhere(test, start);

  @override
  void insert(int index, E element) {
    _base.insert(index, element);
  }

  @override
  void insertAll(int index, Iterable<E> iterable) {
    _base.insertAll(index, iterable);
  }

  @override
  set last(E value) {
    if (isEmpty) throw RangeError.index(0, this);
    this[length - 1] = value;
  }

  @override
  int lastIndexOf(E element, [int? start]) => _base.lastIndexOf(element, start);

  @override
  int lastIndexWhere(bool Function(E) test, [int? start]) =>
      _base.lastIndexWhere(test, start);

  @override
  set length(int newLength) {
    _base.length = newLength;
  }

  @override
  bool remove(Object? value) => _base.remove(value);

  @override
  E removeAt(int index) => _base.removeAt(index);

  @override
  E removeLast() => _base.removeLast();

  @override
  void removeRange(int start, int end) {
    _base.removeRange(start, end);
  }

  @override
  void removeWhere(bool Function(E) test) {
    _base.removeWhere(test);
  }

  @override
  void replaceRange(int start, int end, Iterable<E> iterable) {
    _base.replaceRange(start, end, iterable);
  }

  @override
  void retainWhere(bool Function(E) test) {
    _base.retainWhere(test);
  }

  @override
  Iterable<E> get reversed => _base.reversed;

  @override
  void setAll(int index, Iterable<E> iterable) {
    _base.setAll(index, iterable);
  }

  @override
  void setRange(int start, int end, Iterable<E> iterable, [int skipCount = 0]) {
    _base.setRange(start, end, iterable, skipCount);
  }

  @override
  void shuffle([math.Random? random]) {
    _base.shuffle(random);
  }

  @override
  void sort([int Function(E, E)? compare]) {
    _base.sort(compare);
  }

  @override
  List<E> sublist(int start, [int? end]) => _base.sublist(start, end);
}
