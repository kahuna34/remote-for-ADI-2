import 'package:flutter/material.dart';

import 'theme.dart';

/// Kurzer Start mit dem App-Symbol: Es erscheint, wächst leicht und blendet
/// dann über der bereits aufgebauten Startseite aus. Bei reduzierter
/// Bewegung entfällt die Animation.
class StartAnimation extends StatefulWidget {
  const StartAnimation({super.key, required this.child});
  final Widget child;

  static const duration = Duration(milliseconds: 1400);

  @override
  State<StartAnimation> createState() => _StartAnimationState();
}

class _StartAnimationState extends State<StartAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: StartAnimation.duration,
  );
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _c.forward().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _c.value = 1;
      _done = true;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IgnorePointer(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = _c.value;
              // 0–45 %: Symbol erscheint und wächst, 45–70 %: steht,
              // 70–100 %: Hintergrund und Symbol blenden aus.
              final appear = Curves.easeOutBack.transform(
                (t / 0.45).clamp(0.0, 1.0),
              );
              final fade =
                  1 -
                  Curves.easeIn.transform(((t - 0.7) / 0.3).clamp(0.0, 1.0));
              return Opacity(
                opacity: fade,
                child: ColoredBox(
                  color: Palette.bg,
                  child: Center(
                    child: Opacity(
                      opacity: (t / 0.25).clamp(0.0, 1.0),
                      child: Transform.scale(
                        scale: 0.6 + 0.4 * appear,
                        child: Image.asset(
                          'assets/images/app_icon.png',
                          key: const ValueKey('start-icon'),
                          width: 132,
                          height: 132,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
