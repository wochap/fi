import 'package:fi/src/rust/api/models.dart';
import 'package:fi/voice/engine.dart';

FieldValueDto text(String value) =>
    FieldValueDto(kind: FieldValueKindDto.text, textValue: value);
FieldValueDto decimal(int scaled) =>
    FieldValueDto(kind: FieldValueKindDto.fixedDecimal, integerValue: scaled);
FieldValueDto choice(String id) =>
    FieldValueDto(kind: FieldValueKindDto.enum_, textValue: id);
FieldValueDto date(int day) =>
    FieldValueDto(kind: FieldValueKindDto.date, integerValue: day);

VoicePatchEntry entry(String field, FieldValueDto value, String evidence) =>
    VoicePatchEntry(fieldId: field, value: value, evidence: evidence);

/// description, amount*, category*, date: the expenses collection of the mocks.
const expenseFields = [
  VoiceField(
    id: 'description',
    name: 'description',
    kind: FieldTypeKindDto.text,
  ),
  VoiceField(
    id: 'amount',
    name: 'amount',
    kind: FieldTypeKindDto.fixedDecimal,
    required: true,
    scale: 2,
  ),
  VoiceField(
    id: 'category',
    name: 'category',
    kind: FieldTypeKindDto.enum_,
    required: true,
    options: [
      (id: 'food', label: 'Food'),
      (id: 'transport', label: 'Transport'),
    ],
  ),
  VoiceField(id: 'date', name: 'date', kind: FieldTypeKindDto.date),
];

/// The expenses collection with Spanish names and labels.
const spanishExpenseFields = [
  VoiceField(
    id: 'description',
    name: 'descripción',
    kind: FieldTypeKindDto.text,
  ),
  VoiceField(
    id: 'amount',
    name: 'importe',
    kind: FieldTypeKindDto.fixedDecimal,
    required: true,
    scale: 2,
  ),
  VoiceField(
    id: 'category',
    name: 'categoría',
    kind: FieldTypeKindDto.enum_,
    required: true,
    options: [
      (id: 'comida', label: 'comida'),
      (id: 'transporte', label: 'transporte'),
      (id: 'hogar', label: 'hogar'),
      (id: 'otro', label: 'otro'),
    ],
  ),
  VoiceField(id: 'date', name: 'fecha', kind: FieldTypeKindDto.date),
];

const lunchTranscript = "Lunch at Nando's, twelve fifty, food, yesterday";

final lunchResult = VoiceTurnResult(
  transcript: lunchTranscript,
  patch: [
    entry('description', text("Lunch at Nando's"), "Lunch at Nando's"),
    entry('amount', decimal(1250), 'twelve fifty'),
    entry('category', choice('food'), 'food'),
    entry('date', date(20000), 'yesterday'),
  ],
);

final taxiResult = VoiceTurnResult(
  transcript: 'Taxi home yesterday',
  patch: [
    entry('description', text('Taxi home'), 'Taxi home'),
    entry('date', date(20000), 'yesterday'),
  ],
);

final answerResult = VoiceTurnResult(
  transcript: 'Twenty two forty, transport',
  patch: [
    entry('amount', decimal(2240), 'Twenty two forty'),
    entry('category', choice('transport'), 'transport'),
  ],
);

final categoryOnlyResult = VoiceTurnResult(
  transcript: 'transport',
  patch: [entry('category', choice('transport'), 'transport')],
);

VoiceFillRequest request() =>
    const VoiceFillRequest(fields: expenseFields, draft: {}, language: 'en');

/// A fake engine with near-instant delays for tests.
FakeVoiceEngine quickEngine(List<FakeVoiceTurn> script) => FakeVoiceEngine(
  script: script,
  transcribeDelay: const Duration(milliseconds: 5),
  fillDelay: const Duration(milliseconds: 5),
  levelInterval: const Duration(milliseconds: 50),
);
