import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

void main() {
  test('controller refreshes generic projection events and CRUD', () async {
    final bridge = FakeCollectionBridge();
    final controller = CollectionsController(bridge);
    await controller.start();
    final id = await controller.createCollection('Headaches');
    expect(controller.collections.single.name, 'Headaches');
    await controller.selectCollection(id);
    expect(controller.schema?.id, id);
    bridge.changed(id);
    await Future<void>.delayed(Duration.zero);
    expect(controller.selectedCollectionId, id);
    controller.dispose();
  });

  test('Rust errors remain visible', () async {
    final bridge = FakeCollectionBridge();
    final controller = CollectionsController(bridge);
    await controller.start();
    bridge.nextError = const BridgeError(
      kind: BridgeErrorKind.validation,
      field: 'name',
      message: 'Name is required.',
    );
    await expectLater(
      controller.createCollection(''),
      throwsA(isA<BridgeError>()),
    );
    controller.dispose();
  });

  test('controller drives schema, enum option, and record CRUD', () async {
    final bridge = FakeCollectionBridge();
    final controller = CollectionsController(bridge);
    await controller.start();
    final collection = await controller.createCollection('Symptoms');
    await controller.selectCollection(collection);
    const enumField = FieldDefinitionDto(
      id: '',
      name: 'Severity',
      fieldType: FieldTypeDto(kind: FieldTypeKindDto.enum_),
      required_: true,
      validation: ValidationMetadataDto(),
      display: DisplayMetadataDto(multiline: false),
      order: 0,
      deleted: false,
      enumOptions: [],
    );
    await controller.addField(enumField);
    final fieldId = controller.schema!.fields.single.id;
    await controller.upsertEnumOption(
      fieldId,
      const EnumOptionDto(id: '', label: 'High', order: 0, deleted: false),
    );
    final optionId = controller.schema!.fields.single.enumOptions.single.id;
    await controller.createRecord([
      RecordValueDto(
        fieldId: fieldId,
        value: FieldValueDto(
          kind: FieldValueKindDto.enum_,
          textValue: optionId,
        ),
      ),
    ]);
    expect(controller.records, hasLength(1));
    await controller.updateRecord(controller.records.single.id, [
      RecordValueDto(
        fieldId: fieldId,
        value: FieldValueDto(
          kind: FieldValueKindDto.enum_,
          textValue: optionId,
        ),
      ),
    ]);
    await controller.deleteRecord(controller.records.single.id);
    expect(controller.records, isEmpty);
    await controller.removeEnumOption(fieldId, optionId);
    expect(controller.schema!.fields.single.enumOptions, isEmpty);
    controller.dispose();
  });
}
