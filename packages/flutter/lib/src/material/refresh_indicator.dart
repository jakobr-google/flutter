// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'progress_indicator.dart';
import 'theme.dart';

// The over-scroll distance that moves the indicator to its maximum
// displacement, as a percentage of the scrollable's container extent.
const double _kDragContainerExtentPercentage = 0.25;

// How much the scroll's drag gesture can overshoot the RefreshIndicator's
// displacement; max displacement = _kDragSizeFactorLimit * displacement.
const double _kDragSizeFactorLimit = 1.5;

// When the scroll ends, the duration of the refresh indicator's animation
// to the RefreshIndicator's displacment.
const Duration _kIndicatorSnapDuration = const Duration(milliseconds: 150);

// The duration of the ScaleTransition that starts when the refresh action
// has completed.
const Duration _kIndicatorScaleDuration = const Duration(milliseconds: 200);

/// The signature for a function that's called when the user has dragged a
/// [RefreshIndicator] far enough to demonstrate that they want the app to
/// refresh. The returned [Future] must complete when the refresh operation is
/// finished.
///
/// Used by [RefreshIndicator.onRefresh].
typedef Future<Null> RefreshCallback();

// The state machine moves through these modes only when the scrollable
// identified by scrollableKey has been scrolled to its min or max limit.
enum _RefreshIndicatorMode {
  drag,     // Pointer is down.
  armed,    // Dragged far enough that an up event will run the onRefresh callback.
  snap,     // Animating to the indicator's final "displacement".
  refresh,  // Running the refresh callback.
  done,     // Animating the indicator's fade-out after refreshing.
  canceled, // Animating the indicator's fade-out after not arming.
}

/// A widget that supports the Material "swipe to refresh" idiom.
///
/// When the child's [Scrollable] descendant overscrolls, an animated circular
/// progress indicator is faded into view. When the scroll ends, if the
/// indicator has been dragged far enough for it to become completely opaque,
/// the [onRefresh] callback is called. The callback is expected to update the
/// scrollable's contents and then complete the [Future] it returns. The refresh
/// indicator disappears after the callback's [Future] has completed.
///
/// If the [Scrollable] might not have enough content to overscroll, consider
/// settings its `physics` property to [AlwaysScrollableScrollPhysics]:
///
/// ```dart
/// new ListView(
///   physics: const AlwaysScrollableScrollPhysics(),
///   children: ...
//  )
/// ```
///
/// Using [AlwaysScrollableScrollPhysics] will ensure that the scroll view is
/// always scrollable and, therefore, can trigger the [RefreshIndicator].
///
/// A [RefreshIndicator] can only be used with a vertical scroll view.
///
/// See also:
///
///  * <https://material.google.com/patterns/swipe-to-refresh.html>
///  * [RefreshIndicatorState], can be used to programatically show the refresh indicator.
///  * [RefreshProgressIndicator].
class RefreshIndicator extends StatefulWidget {
  /// Creates a refresh indicator.
  ///
  /// The [onRefresh] and [child] arguments must be non-null. The default
  /// [displacement] is 40.0 logical pixels.
  RefreshIndicator({
    Key key,
    this.child,
    this.displacement: 40.0,
    this.onRefresh,
    this.color,
    this.backgroundColor
  }) : super(key: key) {
    assert(child != null);
    assert(onRefresh != null);
  }

  /// The refresh indicator will be stacked on top of this child. The indicator
  /// will appear when child's Scrollable descendant is over-scrolled.
  final Widget child;

  /// The distance from the child's top or bottom edge to where the refresh
  /// indicator will settle. During the drag that exposes the refresh indicator,
  /// its actual displacement may significantly exceed this value.
  final double displacement;

  /// A function that's called when the user has dragged the refresh indicator
  /// far enough to demonstrate that they want the app to refresh. The returned
  /// [Future] must complete when the refresh operation is finished.
  final RefreshCallback onRefresh;

  /// The progress indicator's foreground color. The current theme's
  /// [ThemeData.accentColor] by default.
  final Color color;

  /// The progress indicator's background color. The current theme's
  /// [ThemeData.canvasColor] by default.
  final Color backgroundColor;

  @override
  RefreshIndicatorState createState() => new RefreshIndicatorState();
}

/// Contains the state for a [RefreshIndicator]. This class can be used to
/// programmatically show the refresh indicator, see the [show] method.
class RefreshIndicatorState extends State<RefreshIndicator> with TickerProviderStateMixin {
  AnimationController _positionController;
  AnimationController _scaleController;
  Animation<double> _positionFactor;
  Animation<double> _scaleFactor;
  Animation<double> _value;
  Animation<Color> _valueColor;

  _RefreshIndicatorMode _mode;
  Future<Null> _pendingRefreshFuture;
  bool _isIndicatorAtTop;
  double _dragOffset;

  @override
  void initState() {
    super.initState();

    _positionController = new AnimationController(vsync: this);
    _positionFactor = new Tween<double>(
      begin: 0.0,
      end: _kDragSizeFactorLimit,
    ).animate(_positionController);
    _value = new Tween<double>( // The "value" of the circular progress indicator during a drag.
      begin: 0.0,
      end: 0.75,
    ).animate(_positionController);

    _scaleController = new AnimationController(vsync: this);
    _scaleFactor = new Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(_scaleController);
  }

  @override
  void didChangeDependencies() {
    final ThemeData theme = Theme.of(context);
    _valueColor = new ColorTween(
      begin: (config.color ?? theme.accentColor).withOpacity(0.0),
      end: (config.color ?? theme.accentColor).withOpacity(1.0)
    ).animate(new CurvedAnimation(
      parent: _positionController,
      curve: const Interval(0.0, 1.0 / _kDragSizeFactorLimit)
    ));
    super.didChangeDependencies();
  }

  @override
  void dispose() {
    _positionController.dispose();
    _scaleController.dispose();
    super.dispose();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0)
      return false;
    if (notification is ScrollStartNotification && notification.metrics.extentBefore == 0.0 &&
        _mode == null && _start(notification.axisDirection)) {
      setState(() {
        _mode = _RefreshIndicatorMode.drag;
      });
      return false;
    }
    bool indicatorAtTopNow;
    switch (notification.axisDirection) {
      case AxisDirection.down:
        indicatorAtTopNow = true;
        break;
      case AxisDirection.up:
        indicatorAtTopNow = false;
        break;
      case AxisDirection.left:
      case AxisDirection.right:
        indicatorAtTopNow = null;
        break;
    }
    if (indicatorAtTopNow != _isIndicatorAtTop) {
      if (_mode == _RefreshIndicatorMode.drag || _mode == _RefreshIndicatorMode.armed)
        _dismiss(_RefreshIndicatorMode.canceled);
    } else if (notification is ScrollUpdateNotification) {
      if (_mode == _RefreshIndicatorMode.drag || _mode == _RefreshIndicatorMode.armed) {
        if (notification.metrics.extentBefore > 0.0) {
          _dismiss(_RefreshIndicatorMode.canceled);
        } else {
          _dragOffset -= notification.scrollDelta;
          _checkDragOffset(notification.metrics.viewportDimension);
        }
      }
    } else if (notification is OverscrollNotification) {
      if (_mode == _RefreshIndicatorMode.drag || _mode == _RefreshIndicatorMode.armed) {
        _dragOffset -= notification.overscroll / 2.0;
        _checkDragOffset(notification.metrics.viewportDimension);
      }
    } else if (notification is ScrollEndNotification) {
      switch (_mode) {
        case _RefreshIndicatorMode.armed:
          _show();
          break;
        case _RefreshIndicatorMode.drag:
          _dismiss(_RefreshIndicatorMode.canceled);
          break;
        default:
          // do nothing
          break;
      }
    }
    return false;
  }

  bool _handleGlowNotification(OverscrollIndicatorNotification notification) {
    if (notification.depth != 0 || !notification.leading)
      return false;
    if (_mode == _RefreshIndicatorMode.drag) {
      notification.disallowGlow();
      return true;
    }
    return false;
  }

  bool _start(AxisDirection direction) {
    assert(_mode == null);
    assert(_isIndicatorAtTop == null);
    assert(_dragOffset == null);
    switch (direction) {
      case AxisDirection.down:
        _isIndicatorAtTop = true;
        break;
      case AxisDirection.up:
        _isIndicatorAtTop = false;
        break;
      case AxisDirection.left:
      case AxisDirection.right:
        _isIndicatorAtTop = null;
        // we do not support horizontal scroll views.
        return false;
    }
    _dragOffset = 0.0;
    _scaleController.value = 0.0;
    _positionController.value = 0.0;
    return true;
  }

  void _checkDragOffset(double containerExtent) {
    assert(_mode == _RefreshIndicatorMode.drag || _mode == _RefreshIndicatorMode.armed);
    double newValue = _dragOffset / (containerExtent * _kDragContainerExtentPercentage);
    if (_mode == _RefreshIndicatorMode.armed)
      newValue = math.max(newValue, 1.0 / _kDragSizeFactorLimit);
    _positionController.value = newValue.clamp(0.0, 1.0); // this triggers various rebuilds
    if (_mode == _RefreshIndicatorMode.drag && _valueColor.value.alpha == 0xFF)
      _mode = _RefreshIndicatorMode.armed;
  }

  // Stop showing the refresh indicator.
  Future<Null> _dismiss(_RefreshIndicatorMode newMode) async {
    // This can only be called from _show() when refreshing and
    // _handleScrollNotification in response to a ScrollEndNotification or
    // direction change.
    assert(newMode == _RefreshIndicatorMode.canceled || newMode == _RefreshIndicatorMode.done);
    setState(() {
      _mode = newMode;
    });
    switch (_mode) {
      case _RefreshIndicatorMode.done:
        await _scaleController.animateTo(1.0, duration: _kIndicatorScaleDuration);
        break;
      case _RefreshIndicatorMode.canceled:
        await _positionController.animateTo(0.0, duration: _kIndicatorScaleDuration);
        break;
      default:
        assert(false);
    }
    if (mounted && _mode == newMode) {
      _dragOffset = null;
      _isIndicatorAtTop = null;
      setState(() {
        _mode = null;
      });
    }
  }

  void _show() {
    assert(_mode != _RefreshIndicatorMode.refresh);
    assert(_mode != _RefreshIndicatorMode.snap);
    final Completer<Null> completer = new Completer<Null>();
    _pendingRefreshFuture = completer.future;
    _mode = _RefreshIndicatorMode.snap;
    _positionController
      .animateTo(1.0 / _kDragSizeFactorLimit, duration: _kIndicatorSnapDuration)
      .whenComplete(() {
        if (mounted && _mode == _RefreshIndicatorMode.snap) {
          assert(config.onRefresh != null);
          setState(() {
            // Show the indeterminate progress indicator.
            _mode = _RefreshIndicatorMode.refresh;
          });

          config.onRefresh().whenComplete(() {
            if (mounted && _mode == _RefreshIndicatorMode.refresh) {
              completer.complete();
              _dismiss(_RefreshIndicatorMode.done);
            }
          });
        }
      });
  }

  /// Show the refresh indicator and run the refresh callback as if it had
  /// been started interactively. If this method is called while the refresh
  /// callback is running, it quietly does nothing.
  ///
  /// Creating the [RefreshIndicator] with a [GlobalKey<RefreshIndicatorState>]
  /// makes it possible to refer to the [RefreshIndicatorState].
  ///
  /// The future returned from this method completes when the [onRefresh]
  /// callback's future completes.
  ///
  /// If you await the future returned by this function from a [State], you
  /// should check that the state is still [mounted] before calling [setState].
  ///
  /// When initiated in this manner, the refresh indicator is independent of any
  /// actual scroll view. It defaults to showing the indicator at the top. To
  /// show it at the bottom, set `atTop` to false.
  Future<Null> show({ bool atTop: true }) {
    if (_mode != _RefreshIndicatorMode.refresh &&
        _mode != _RefreshIndicatorMode.snap) {
      if (_mode == null)
        _start(atTop ? AxisDirection.down : AxisDirection.up);
      _show();
    }
    return _pendingRefreshFuture;
  }

  final GlobalKey _key = new GlobalKey();

  @override
  Widget build(BuildContext context) {
    final Widget child = new NotificationListener<ScrollNotification>(
      key: _key,
      onNotification: _handleScrollNotification,
      child: new NotificationListener<OverscrollIndicatorNotification>(
        onNotification: _handleGlowNotification,
        child: config.child,
      ),
    );
    if (_mode == null) {
      assert(_dragOffset == null);
      assert(_isIndicatorAtTop == null);
      return child;
    }
    assert(_dragOffset != null);
    assert(_isIndicatorAtTop != null);

    final bool showIndeterminateIndicator =
      _mode == _RefreshIndicatorMode.refresh || _mode == _RefreshIndicatorMode.done;

    return new Stack(
      children: <Widget>[
        child,
        new Positioned(
          top: _isIndicatorAtTop ? 0.0 : null,
          bottom: !_isIndicatorAtTop ? 0.0 : null,
          left: 0.0,
          right: 0.0,
          child: new SizeTransition(
            axisAlignment: _isIndicatorAtTop ? 1.0 : 0.0,
            sizeFactor: _positionFactor, // this is what brings it down
            child: new Container(
              padding: _isIndicatorAtTop
                ? new EdgeInsets.only(top: config.displacement)
                : new EdgeInsets.only(bottom: config.displacement),
              alignment: _isIndicatorAtTop
                ? FractionalOffset.topCenter
                : FractionalOffset.bottomCenter,
              child: new ScaleTransition(
                scale: _scaleFactor,
                child: new AnimatedBuilder(
                  animation: _positionController,
                  builder: (BuildContext context, Widget child) {
                    return new RefreshProgressIndicator(
                      value: showIndeterminateIndicator ? null : _value.value,
                      valueColor: _valueColor,
                      backgroundColor: config.backgroundColor,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
