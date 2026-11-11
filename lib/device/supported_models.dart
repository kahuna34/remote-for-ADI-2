import '../protocol/adi2_params.dart';

enum DeviceFamily { dac, pro, pro4 }

typedef SupportedModel = ({
  String name,
  Adi2Variant variant,
  DeviceFamily family,
});

/// Unterstützte Anzeigenamen, Protokollvarianten und Familien für die Anzeige.
/// Pro und Pro EX verwenden dieselbe Geräte-ID und dieselben Parameter.
const supportedModels = <SupportedModel>[
  (name: 'ADI-2 DAC', variant: Adi2Variant.dac, family: DeviceFamily.dac),
  (name: 'ADI-2 Pro', variant: Adi2Variant.pro, family: DeviceFamily.pro),
  (name: 'ADI-2 Pro EX', variant: Adi2Variant.pro, family: DeviceFamily.pro),
  (
    name: 'ADI-2/4 Pro SE',
    variant: Adi2Variant.pro4se,
    family: DeviceFamily.pro4,
  ),
  (
    name: 'ADI-2/4 Pro EX',
    variant: Adi2Variant.pro4ex,
    family: DeviceFamily.pro4,
  ),
];

/// ADI-2 Pro EX: achtstellige Seriennummer, die genau mit 5601 beginnt.
/// Andere Nummern ab 56 gehören zu Vorgängern des ADI-2 Pro.
bool isProExSerial(String? serial) =>
    serial != null && RegExp(r'^5601\d{4}$').hasMatch(serial);
