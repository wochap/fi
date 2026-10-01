import 'package:fi/l10n/error_text.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final _en = lookupAppLocalizations(const Locale('en'));
final _es = lookupAppLocalizations(const Locale('es'));

FieldDefinitionDto _integerField({int? min, int? max}) => FieldDefinitionDto(
  id: 'f',
  name: 'Intensity',
  fieldType: const FieldTypeDto(kind: FieldTypeKindDto.integer),
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

  test('length without a field gives the boundless line', () {
    expect(issueText(_en, _issue('length')), 'Length is not allowed');
    expect(issueText(_es, _issue('length')), 'La longitud no está permitida');
  });

  test('an invalid issue keeps the Rust message', () {
    expect(issueText(_es, _issue('invalid', 'must be even')), 'must be even');
  });

  test('exhausted ports name the range', () {
    final text = networkingDeferredText(
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
    expect(text, allOf(contains('47380'), contains('47389')));
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
