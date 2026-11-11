// Lautstärke-Ring: gefüllter Bogen = Ist-Wert am Gerät, hohler Punkt = Ziel,
// rote Marke/Zone = Obergrenze. Bedienung durch Ziehen entlang des Bogens.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'theme.dart';
import 'responsive_layout.dart';

const double _start = 135; // Grad, unten links
const double _sweep = 270;

/// Sichtbare Höhe relativ zur Breite (Bogenenden + Beschriftung).
const double _heightRatio = 0.83;

/// Lautstärke (dB) -> Anteil 0..1 auf dem Bogen. Unterhalb von −90 dB wird
/// gestaucht, damit der praktisch genutzte Bereich Platz bekommt.
double dbToFrac(double db) {
  if (db <= -90) return ((db + 114.5) / 24.5 * 0.05).clamp(0.0, 0.05);
  return (0.05 + (db + 90) / 96 * 0.95).clamp(0.0, 1.0);
}

double fracToDb(double f) {
  if (f <= 0.05) return -114.5 + f / 0.05 * 24.5;
  return -90 + (f - 0.05) / 0.95 * 96;
}

class VolumeRing extends StatefulWidget {
  const VolumeRing({
    super.key,
    required this.actualDb,
    required this.targetDb,
    required this.limitDb,
    required this.muted,
    required this.enabled,
    required this.onChanged,
    required this.onRelease,
    this.levelText,
  });

  final double actualDb;
  final double? targetDb;
  final double limitDb;
  final bool muted;
  final bool enabled;
  final ValueChanged<double> onChanged; // gewünschte dB (0,5er Raster)
  final VoidCallback onRelease;

  /// Ausgangspegel in dBu (z. B. "RCA +2,0 dBu   XLR +8,0 dBu").
  final String? levelText;

  @override
  State<VolumeRing> createState() => _VolumeRingState();
}

class _VolumeRingState extends State<VolumeRing> {
  double _frac = 0; // aktuelle Reglerstellung 0..1 (relativ verändert)
  double? _prevAngle; // letzter Winkel des Fingers (Grad)
  Size _size = Size.zero;

  double _angle(Offset local) {
    final c = Offset(_size.width / 2, _size.width / 2);
    final v = local - c;
    return math.atan2(v.dy, v.dx) * 180 / math.pi;
  }

  /// Liegt der Punkt auf dem Ring-Band (nicht in der Mitte, nicht außen)?
  bool _onBand(Offset local) {
    final c = Offset(_size.width / 2, _size.width / 2);
    final d = (local - c).distance;
    final r = _size.width / 2 - 36;
    return d > r - 46 && d < r + 44;
  }

  void _start(Offset local) {
    _frac = dbToFrac(widget.targetDb ?? widget.actualDb);
    _prevAngle = _angle(local);
  }

  /// Relatives Drehen: nur die Winkeländerung zählt, kein Springen.
  void _update(Offset local) {
    final prev = _prevAngle;
    if (prev == null) return;
    final ang = _angle(local);
    var delta = ang - prev;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    _prevAngle = ang;
    // Sehr nah an der Mitte sind Winkel unzuverlässig – ignorieren.
    final c = Offset(_size.width / 2, _size.width / 2);
    if ((local - c).distance < 30) return;
    _frac = (_frac + delta / _sweep).clamp(0.0, 1.0);
    final db = (fracToDb(_frac) * 2).round() / 2;
    widget.onChanged(db.clamp(-114.5, 6.0));
  }

  void _end() {
    if (_prevAngle == null) return;
    _prevAngle = null;
    widget.onRelease();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final maximum = isTablet(context) ? 420.0 : 300.0;
        final side = math.min(
          math.min(box.maxWidth, maximum),
          box.maxHeight.isFinite ? box.maxHeight / _heightRatio : maximum,
        );
        final size = Size(side, side * _heightRatio);
        _size = size;
        return Align(
          alignment: Alignment.bottomCenter,
          child: RawGestureDetector(
            gestures: widget.enabled
                ? {
                    _RingDrag: GestureRecognizerFactoryWithHandlers<_RingDrag>(
                      () => _RingDrag(),
                      (r) => r
                        ..accepts = _onBand
                        ..onStart = ((d) => _start(d.localPosition))
                        ..onUpdate = ((d) => _update(d.localPosition))
                        ..onEnd = ((_) => _end())
                        ..onCancel = _end,
                    ),
                  }
                : const {},
            child: SizedBox.fromSize(
              size: size,
              child: CustomPaint(
                painter: _RingPainter(
                  widget.actualDb,
                  widget.targetDb,
                  widget.limitDb,
                  widget.muted,
                ),
                child: Stack(
                  children: [
                    // Zahl genau in der Ringmitte
                    Positioned(
                      left: side * 0.18,
                      right: side * 0.18,
                      top: side * 0.5 - side * 0.19,
                      height: side * 0.28,
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            widget.muted ? tr('Mute') : _fmt(widget.actualDb),
                            style: ts(
                              side * 0.19,
                              weight: 300,
                              width: 112,
                              color: widget.muted ? Palette.red : Palette.text,
                              spacing: -1,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Beschriftung darunter
                    Positioned(
                      left: side * 0.15,
                      right: side * 0.15,
                      top: side * 0.5 + side * 0.07,
                      bottom: 0,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.topCenter,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              tr('dB am Gerät'),
                              style: ts(
                                isTablet(context) ? 16 : 14,
                                weight: 500,
                                color: Palette.muted,
                              ),
                            ),
                            if (widget.levelText != null && !widget.muted)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  widget.levelText!,
                                  textAlign: TextAlign.center,
                                  style: ts(
                                    13,
                                    weight: 600,
                                    color: Palette.amber,
                                    narrow: true,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

String _fmt(double db) =>
    '${db < 0 ? '−' : (db > 0 ? '+' : '')}${db.abs().toStringAsFixed(1).replaceAll('.', ',')}';

String fmtDb(double db) => '${_fmt(db)} dB';

class _RingPainter extends CustomPainter {
  _RingPainter(this.actual, this.target, this.limit, this.muted);
  final double actual;
  final double? target;
  final double limit;
  final bool muted;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.width / 2);
    final r = size.width / 2 - 36;
    final rect = Rect.fromCircle(center: c, radius: r);
    double rad(double f) => (_start + _sweep * f) * math.pi / 180;
    Offset at(double f, double rr) =>
        c + Offset(math.cos(rad(f)) * rr, math.sin(rad(f)) * rr);
    Paint stroke(Color col, double w, {StrokeCap cap = StrokeCap.round}) =>
        Paint()
          ..color = col
          ..strokeWidth = w
          ..style = PaintingStyle.stroke
          ..strokeCap = cap;
    void arc(double f0, double f1, Paint p) {
      if (f1 <= f0) return;
      canvas.drawArc(rect, rad(f0), rad(f1) - rad(f0), false, p);
    }

    final fa = dbToFrac(actual), fl = dbToFrac(limit);
    arc(0, 1, stroke(Palette.surf2, 16));
    // Deckend vorgemischt, damit sich überlappende Stücke nicht verstärken.
    final limitRed = Color.alphaBlend(
      Palette.red.withValues(alpha: 0.35),
      Palette.surf2,
    );
    if (limit < 6) {
      arc(fl, 1, stroke(limitRed, 16, cap: StrokeCap.butt));
      // Runde Kappe am Ende, damit Rot bis zum Ende der Spur reicht.
      if (fl < 0.999) {
        arc(0.999, 1, stroke(limitRed, 16));
      }
    }
    final active = muted ? Palette.muted : Palette.amber;
    arc(0, fa, stroke(active, 16));
    if (target != null && target! > actual) {
      final ft = dbToFrac(target!);
      final p = stroke(
        Palette.amber.withValues(alpha: 0.35),
        16,
        cap: StrokeCap.butt,
      );
      // gestrichelt
      const seg = 0.012;
      for (var f = fa; f < ft; f += seg * 2) {
        arc(f, math.min(f + seg, ft), p);
      }
    }
    // Skala
    final tick = stroke(Palette.line, 2);
    for (var d = -90; d <= 0; d += 10) {
      final f = dbToFrac(d.toDouble());
      canvas.drawLine(at(f, r + 14), at(f, r + 22), tick);
    }
    for (final d in [-90, -60, -30, 0]) {
      final tp = TextPainter(
        text: TextSpan(
          text: d == 0 ? '0' : '−${-d}',
          style: ts(12, weight: 500, color: Palette.muted, narrow: true),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final p = at(dbToFrac(d.toDouble()), r + 32);
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
    }
    if (limit < 6) {
      canvas.drawLine(at(fl, r - 14), at(fl, r + 22), stroke(Palette.red, 3));
    }
    if (target != null && (target! - actual).abs() >= 0.1) {
      final pt = at(dbToFrac(target!), r);
      canvas.drawCircle(pt, 9, Paint()..color = Palette.bg);
      canvas.drawCircle(pt, 9, stroke(Palette.amber, 2.5));
    }
    final pa = at(fa, r);
    canvas.drawCircle(pa, 16, Paint()..color = Palette.bg);
    canvas.drawCircle(pa, 12, Paint()..color = active);
  }

  @override
  bool shouldRepaint(_RingPainter o) =>
      o.actual != actual ||
      o.target != target ||
      o.limit != limit ||
      o.muted != muted;
}

/// Zieh-Erkenner, der eine Berührung auf dem Ring-Band sofort für sich
/// beansprucht – sonst würde die scrollbare Seite senkrechte Bewegungen
/// (rechte Ringseite, hohe Lautstärken) abfangen.
class _RingDrag extends PanGestureRecognizer {
  bool Function(Offset local) accepts = (_) => false;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      super.isPointerAllowed(event) && accepts(event.localPosition);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}
