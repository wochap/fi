import 'package:fi/l10n/error_text.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final _en = lookupAppLocalizations(const Locale('en'));
final _es = lookupAppLocalizations(const Locale('es'));

FieldDefinitionDto _integerField({int? min, int? max}) =>
    _field(FieldTypeKindDto.integer, min: min, max: max);

FieldDefinitionDto _field(FieldTypeKindDto kind, {int? min, int? max}) =>
    FieldDefinitionDto(
      id: 'f',
      name: 'Intensity',
      fieldType: FieldTypeDto(kind: kind),
      required_: false,
      validation: ValidationMetadataDto(minInteger: min, maxInteger: max),
      display: const DisplayMetadataDto(
        multiline: false,
        slider: false,
        sliderStep: null,
      ),
      order: 0,
      deleted: false,
      enumOptions: const [],
    );

BridgeIssueDto _issue(String code, [String message = 'Rust text']) =>
    BridgeIssueDto(fields: const ['f'], code: code, message: message);

void main() {
  test('a required issue is localized', () {
    expect(issueText(_es, _issue('required')), 'Obligatorio');
    expect(issueText(_en, _issue('required')), 'Required');
  });

  test('out of range names the field bounds', () {
    final text = issueText(
      _en,
      _issue('out_of_range'),
      field: _integerField(min: 1, max: 10),
    );
    expect(text, 'Must be between 1 and 10');
    expect(
      issueText(
        _es,
        _issue('out_of_range'),
        field: _integerField(min: 1, max: 10),
      ),
      allOf(contains('1'), contains('10')),
    );
  });

  group('date bounds read as dates', () {
    final day =
        DateTime.utc(2026).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;
    final lastDay =
        DateTime.utc(2026, 12, 31).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;

    test('a Date minimum reads on or after', () {
      expect(
        issueText(
          _en,
          _issue('out_of_range'),
          field: _field(FieldTypeKindDto.date, min: day),
        ),
        'Must be on or after 2026-01-01',
      );
    });

    test('a Date & time maximum reads on or before', () {
      final max = DateTime(2026, 12, 31, 18).millisecondsSinceEpoch;
      expect(
        issueText(
          _en,
          _issue('out_of_range'),
          field: _field(FieldTypeKindDto.dateTime, max: max),
        ),
        'Must be on or before 2026-12-31 18:00',
      );
    });

    test('both Date bounds read between', () {
      expect(
        issueText(
          _en,
          _issue('out_of_range'),
          field: _field(FieldTypeKindDto.date, min: day, max: lastDay),
        ),
        'Must be between 2026-01-01 and 2026-12-31',
      );
    });

    test('an Integer minimum keeps at least', () {
      expect(
        issueText(_en, _issue('out_of_range'), field: _integerField(min: 5)),
        'Must be at least 5',
      );
    });

    test('Spanish', () {
      expect(
        issueText(
          _es,
          _issue('out_of_range'),
          field: _field(FieldTypeKindDto.date, min: day),
        ),
        'Debe ser el 2026-01-01 o posterior',
      );
    });
  });

  test('length without a field gives the boundless line', () {
    expect(issueText(_en, _issue('length')), 'Length is not allowed');
    expect(issueText(_es, _issue('length')), 'La longitud no está permitida');
  });

  test('an invalid issue keeps the Rust message', () {
    expect(issueText(_es, _issue('invalid', 'must be even')), 'must be even');
  });

  test('exhausted ports name the range', () {
    final text = networkingDeferredTitle(
      _es,
      const NetworkingDeferredDto(
        kind: NetworkingDeferredKindDto.portsExhausted,
        message: '',
      ),
      const NetworkPortsDto(
        rangeFirst: 47380,
        rangeLast: 47389,
        mdnsPort: 5353,
      ),
    );
    expect(text, 'Sincronización desactivada: UDP 47380–47389 están en uso');
  });

  test('each deferred kind has a title, body and cause', () {
    for (final kind in NetworkingDeferredKindDto.values) {
      final deferred = NetworkingDeferredDto(kind: kind, message: '');
      expect(
        networkingDeferredTitle(_en, deferred, null),
        startsWith('Sync is off: '),
      );
      expect(networkingDeferredBody(_en, deferred), isNotEmpty);
    }
    expect(
      deferredCause(_en, NetworkingDeferredKindDto.secureStoreLocked),
      'keyring locked',
    );
    expect(
      deferredCause(_en, NetworkingDeferredKindDto.secureStoreUnavailable),
      'no keyring',
    );
    expect(
      deferredCause(_en, NetworkingDeferredKindDto.portsExhausted),
      'ports in use',
    );
  });

  test('a failure that is not a BridgeError is unexpected', () {
    expect(bridgeMessage(_en, StateError('x')), _en.errorUnexpected);
    expect(bridgeMessage(_es, StateError('x')), _es.errorUnexpected);
  });

  test('a bridge error kind is localized', () {
    const error = BridgeError(
      kind: BridgeErrorKind.persistence,
      issues: [],
      message: 'Local data could not be saved or loaded.',
      resetResolvable: false,
    );
    expect(bridgeMessage(_es, error), _es.errorPersistence);
  });
}
