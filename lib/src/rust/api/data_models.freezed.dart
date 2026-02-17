// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'data_models.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ChatStreamEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ChatStreamEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ChatStreamEvent()';
}


}

/// @nodoc
class $ChatStreamEventCopyWith<$Res>  {
$ChatStreamEventCopyWith(ChatStreamEvent _, $Res Function(ChatStreamEvent) __);
}


/// Adds pattern-matching-related methods to [ChatStreamEvent].
extension ChatStreamEventPatterns on ChatStreamEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( ChatStreamEvent_ContentDelta value)?  contentDelta,TResult Function( ChatStreamEvent_ThinkingDelta value)?  thinkingDelta,TResult Function( ChatStreamEvent_Done value)?  done,TResult Function( ChatStreamEvent_Error value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case ChatStreamEvent_ContentDelta() when contentDelta != null:
return contentDelta(_that);case ChatStreamEvent_ThinkingDelta() when thinkingDelta != null:
return thinkingDelta(_that);case ChatStreamEvent_Done() when done != null:
return done(_that);case ChatStreamEvent_Error() when error != null:
return error(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( ChatStreamEvent_ContentDelta value)  contentDelta,required TResult Function( ChatStreamEvent_ThinkingDelta value)  thinkingDelta,required TResult Function( ChatStreamEvent_Done value)  done,required TResult Function( ChatStreamEvent_Error value)  error,}){
final _that = this;
switch (_that) {
case ChatStreamEvent_ContentDelta():
return contentDelta(_that);case ChatStreamEvent_ThinkingDelta():
return thinkingDelta(_that);case ChatStreamEvent_Done():
return done(_that);case ChatStreamEvent_Error():
return error(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( ChatStreamEvent_ContentDelta value)?  contentDelta,TResult? Function( ChatStreamEvent_ThinkingDelta value)?  thinkingDelta,TResult? Function( ChatStreamEvent_Done value)?  done,TResult? Function( ChatStreamEvent_Error value)?  error,}){
final _that = this;
switch (_that) {
case ChatStreamEvent_ContentDelta() when contentDelta != null:
return contentDelta(_that);case ChatStreamEvent_ThinkingDelta() when thinkingDelta != null:
return thinkingDelta(_that);case ChatStreamEvent_Done() when done != null:
return done(_that);case ChatStreamEvent_Error() when error != null:
return error(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String field0)?  contentDelta,TResult Function( String field0)?  thinkingDelta,TResult Function()?  done,TResult Function( String field0)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case ChatStreamEvent_ContentDelta() when contentDelta != null:
return contentDelta(_that.field0);case ChatStreamEvent_ThinkingDelta() when thinkingDelta != null:
return thinkingDelta(_that.field0);case ChatStreamEvent_Done() when done != null:
return done();case ChatStreamEvent_Error() when error != null:
return error(_that.field0);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String field0)  contentDelta,required TResult Function( String field0)  thinkingDelta,required TResult Function()  done,required TResult Function( String field0)  error,}) {final _that = this;
switch (_that) {
case ChatStreamEvent_ContentDelta():
return contentDelta(_that.field0);case ChatStreamEvent_ThinkingDelta():
return thinkingDelta(_that.field0);case ChatStreamEvent_Done():
return done();case ChatStreamEvent_Error():
return error(_that.field0);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String field0)?  contentDelta,TResult? Function( String field0)?  thinkingDelta,TResult? Function()?  done,TResult? Function( String field0)?  error,}) {final _that = this;
switch (_that) {
case ChatStreamEvent_ContentDelta() when contentDelta != null:
return contentDelta(_that.field0);case ChatStreamEvent_ThinkingDelta() when thinkingDelta != null:
return thinkingDelta(_that.field0);case ChatStreamEvent_Done() when done != null:
return done();case ChatStreamEvent_Error() when error != null:
return error(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class ChatStreamEvent_ContentDelta extends ChatStreamEvent {
  const ChatStreamEvent_ContentDelta(this.field0): super._();
  

 final  String field0;

/// Create a copy of ChatStreamEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ChatStreamEvent_ContentDeltaCopyWith<ChatStreamEvent_ContentDelta> get copyWith => _$ChatStreamEvent_ContentDeltaCopyWithImpl<ChatStreamEvent_ContentDelta>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ChatStreamEvent_ContentDelta&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'ChatStreamEvent.contentDelta(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $ChatStreamEvent_ContentDeltaCopyWith<$Res> implements $ChatStreamEventCopyWith<$Res> {
  factory $ChatStreamEvent_ContentDeltaCopyWith(ChatStreamEvent_ContentDelta value, $Res Function(ChatStreamEvent_ContentDelta) _then) = _$ChatStreamEvent_ContentDeltaCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$ChatStreamEvent_ContentDeltaCopyWithImpl<$Res>
    implements $ChatStreamEvent_ContentDeltaCopyWith<$Res> {
  _$ChatStreamEvent_ContentDeltaCopyWithImpl(this._self, this._then);

  final ChatStreamEvent_ContentDelta _self;
  final $Res Function(ChatStreamEvent_ContentDelta) _then;

/// Create a copy of ChatStreamEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(ChatStreamEvent_ContentDelta(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ChatStreamEvent_ThinkingDelta extends ChatStreamEvent {
  const ChatStreamEvent_ThinkingDelta(this.field0): super._();
  

 final  String field0;

/// Create a copy of ChatStreamEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ChatStreamEvent_ThinkingDeltaCopyWith<ChatStreamEvent_ThinkingDelta> get copyWith => _$ChatStreamEvent_ThinkingDeltaCopyWithImpl<ChatStreamEvent_ThinkingDelta>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ChatStreamEvent_ThinkingDelta&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'ChatStreamEvent.thinkingDelta(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $ChatStreamEvent_ThinkingDeltaCopyWith<$Res> implements $ChatStreamEventCopyWith<$Res> {
  factory $ChatStreamEvent_ThinkingDeltaCopyWith(ChatStreamEvent_ThinkingDelta value, $Res Function(ChatStreamEvent_ThinkingDelta) _then) = _$ChatStreamEvent_ThinkingDeltaCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$ChatStreamEvent_ThinkingDeltaCopyWithImpl<$Res>
    implements $ChatStreamEvent_ThinkingDeltaCopyWith<$Res> {
  _$ChatStreamEvent_ThinkingDeltaCopyWithImpl(this._self, this._then);

  final ChatStreamEvent_ThinkingDelta _self;
  final $Res Function(ChatStreamEvent_ThinkingDelta) _then;

/// Create a copy of ChatStreamEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(ChatStreamEvent_ThinkingDelta(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ChatStreamEvent_Done extends ChatStreamEvent {
  const ChatStreamEvent_Done(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ChatStreamEvent_Done);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ChatStreamEvent.done()';
}


}




/// @nodoc


class ChatStreamEvent_Error extends ChatStreamEvent {
  const ChatStreamEvent_Error(this.field0): super._();
  

 final  String field0;

/// Create a copy of ChatStreamEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ChatStreamEvent_ErrorCopyWith<ChatStreamEvent_Error> get copyWith => _$ChatStreamEvent_ErrorCopyWithImpl<ChatStreamEvent_Error>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ChatStreamEvent_Error&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'ChatStreamEvent.error(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $ChatStreamEvent_ErrorCopyWith<$Res> implements $ChatStreamEventCopyWith<$Res> {
  factory $ChatStreamEvent_ErrorCopyWith(ChatStreamEvent_Error value, $Res Function(ChatStreamEvent_Error) _then) = _$ChatStreamEvent_ErrorCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$ChatStreamEvent_ErrorCopyWithImpl<$Res>
    implements $ChatStreamEvent_ErrorCopyWith<$Res> {
  _$ChatStreamEvent_ErrorCopyWithImpl(this._self, this._then);

  final ChatStreamEvent_Error _self;
  final $Res Function(ChatStreamEvent_Error) _then;

/// Create a copy of ChatStreamEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(ChatStreamEvent_Error(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
