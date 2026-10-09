// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get navCollections => 'Colecciones';

  @override
  String get navDevices => 'Dispositivos';

  @override
  String get navSettings => 'Ajustes';

  @override
  String get settingsLanguage => 'Idioma';

  @override
  String get langAppLanguage => 'Idioma de la app';

  @override
  String get langAppLanguageHint =>
      'Menús, etiquetas y fechas. Los cambios se aplican al instante.';

  @override
  String get langSystemDefault => 'Predeterminado del sistema';

  @override
  String langSystemDefaultNamed(String language) {
    return 'Predeterminado del sistema ($language)';
  }

  @override
  String langSameAsPhone(String language) {
    return '$language — igual que tu teléfono';
  }

  @override
  String get errorUnexpected =>
      'El servicio local de colecciones tuvo un error inesperado.';

  @override
  String get errorInitialization =>
      'No se pudo iniciar la red segura entre dispositivos.';

  @override
  String get errorSecureStoreLocked =>
      'Tu llavero de inicio de sesión está bloqueado, así que la red segura entre dispositivos no puede iniciar. Desbloquea el llavero y vuelve a intentarlo.';

  @override
  String get errorPaused =>
      'La sincronización con dispositivos emparejados está desactivada.';

  @override
  String get errorBootstrap =>
      'No se pueden abrir los datos locales de este dispositivo.';

  @override
  String get errorPersistence =>
      'No se pudieron guardar ni cargar los datos locales.';

  @override
  String get errorProjection =>
      'No se pudo actualizar la vista local de los datos.';

  @override
  String get errorLifecycle =>
      'No se pudo contactar al dispositivo, o el servicio local no está en ejecución.';

  @override
  String get errorInternal =>
      'Esta versión de la app no admite los datos locales de colecciones.';

  @override
  String errorValidation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count problemas requieren atención',
      one: '1 problema requiere atención',
    );
    return '$_temp0';
  }

  @override
  String get issueRequired => 'Obligatorio';

  @override
  String get issueTypeMismatch =>
      'El valor no coincide con el tipo de este campo';

  @override
  String get issueInactiveOption => 'Elige una opción activa';

  @override
  String get issueFieldUnavailable => 'Este campo ya no está disponible';

  @override
  String issueLengthRange(int min, int max) {
    return 'Debe tener entre $min y $max caracteres';
  }

  @override
  String issueLengthExact(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Debe tener exactamente $count caracteres',
      one: 'Debe tener exactamente 1 carácter',
    );
    return '$_temp0';
  }

  @override
  String issueLengthMin(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Debe tener al menos $count caracteres',
      one: 'Debe tener al menos 1 carácter',
    );
    return '$_temp0';
  }

  @override
  String issueLengthMax(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Debe tener como máximo $count caracteres',
      one: 'Debe tener como máximo 1 carácter',
    );
    return '$_temp0';
  }

  @override
  String get issueLength => 'La longitud no está permitida';

  @override
  String issueRangeBetween(String min, String max) {
    return 'Debe estar entre $min y $max';
  }

  @override
  String issueRangeMin(String min) {
    return 'Debe ser al menos $min';
  }

  @override
  String issueRangeMax(String max) {
    return 'Debe ser como máximo $max';
  }

  @override
  String get issueRange => 'El valor está fuera de rango';

  @override
  String get pairingDidNotComplete => 'El emparejamiento no se completó.';

  @override
  String get widgetErrorRemoved => 'Este widget se eliminó.';

  @override
  String get widgetErrorUnsupportedType =>
      'Esta versión de la app no admite este tipo de widget.';

  @override
  String get widgetErrorUnsupportedConfigurationVersion =>
      'Este widget se guardó con una versión más reciente de la app.';

  @override
  String get widgetErrorInvalidConfiguration =>
      'La configuración de este widget no es válida.';

  @override
  String get widgetErrorUnknownQuery =>
      'La consulta guardada de este widget ya no está disponible.';

  @override
  String get widgetErrorInvalidQuery =>
      'La consulta guardada de este widget no es válida.';

  @override
  String get widgetErrorShapeMismatch =>
      'La consulta guardada devuelve un resultado que este widget no puede mostrar.';

  @override
  String get widgetErrorOverflow =>
      'El resultado es demasiado grande para calcularlo con exactitud.';

  @override
  String get widgetErrorQueryFailed =>
      'No se pudo ejecutar la consulta guardada.';

  @override
  String importRecords(int count, String name) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Se importaron $count registros en $name',
      one: 'Se importó 1 registro en $name',
    );
    return '$_temp0';
  }

  @override
  String importCollections(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Se importaron $count colecciones',
      one: 'Se importó 1 colección',
    );
    return '$_temp0';
  }

  @override
  String importStoppedAt(String place, String reason) {
    return 'La importación se detuvo en $place: $reason No se importó nada.';
  }

  @override
  String importStopped(String reason) {
    return 'La importación se detuvo: $reason No se importó nada.';
  }

  @override
  String get importPlaceHeader => 'el encabezado';

  @override
  String importPlaceRow(int row) {
    return 'fila $row';
  }

  @override
  String importPlaceCollection(int index) {
    return 'colección $index';
  }

  @override
  String get widgetNotEvaluated => 'No se pudo evaluar este widget.';

  @override
  String get commonYes => 'Sí';

  @override
  String get commonNo => 'No';

  @override
  String get timeNever => 'nunca';

  @override
  String get timeJustNow => 'justo ahora';

  @override
  String timeMinutesAgo(int minutes) {
    return 'hace $minutes min';
  }

  @override
  String timeHoursAgo(int hours) {
    return 'hace $hours h';
  }

  @override
  String get devicesNeverSeen => 'Nunca visto';

  @override
  String get devicesNeverSynced => 'Nunca sincronizado';

  @override
  String devicesSeen(String time) {
    return 'Visto $time';
  }

  @override
  String devicesSynced(String time) {
    return 'Sincronizado $time';
  }

  @override
  String timeLeftMinutes(int minutes) {
    return 'faltan unos $minutes min';
  }

  @override
  String timeLeftSeconds(int seconds) {
    return 'faltan unos $seconds s';
  }

  @override
  String get commonCancel => 'Cancelar';

  @override
  String get commonSave => 'Guardar';

  @override
  String get commonDelete => 'Eliminar';

  @override
  String get commonClose => 'Cerrar';

  @override
  String get commonDone => 'Listo';

  @override
  String get commonRetry => 'Reintentar';

  @override
  String get commonTryAgain => 'Intentar de nuevo';

  @override
  String get commonShow => 'Mostrar';

  @override
  String get commonClear => 'Borrar';

  @override
  String get commonRename => 'Cambiar nombre';

  @override
  String get commonEdit => 'Editar';

  @override
  String get commonAdd => 'Agregar';

  @override
  String get commonBack => 'Atrás';

  @override
  String get commonOk => 'Aceptar';

  @override
  String get commonCopy => 'Copiar';

  @override
  String get commonNone => 'Ninguno';

  @override
  String get commonLoading => 'Cargando…';

  @override
  String get commonRequired => 'Obligatorio';

  @override
  String get commonDetails => 'Detalles';

  @override
  String get commonNew => 'Nuevo';

  @override
  String get themeChoose => 'Elegir…';

  @override
  String themeSearchOptions(int count) {
    return 'Buscar entre $count opciones';
  }

  @override
  String themeTypeToSearchOptions(int count) {
    return 'Escribe para buscar entre $count opciones';
  }

  @override
  String themeMatchesFooter(int matches, int total) {
    return '$matches de $total · ↑↓ para moverte, Enter para elegir';
  }

  @override
  String get themeSearch => 'Buscar';

  @override
  String get themeMore => 'Más';

  @override
  String get themeSet => 'Fijar';

  @override
  String get themeVoice => 'Voz';

  @override
  String themeFilledByVoice(String field) {
    return '$field, completado por voz';
  }

  @override
  String get themeDefault => 'Predeterminado';

  @override
  String get themeNeeded => 'Falta';

  @override
  String get queryPresetDailyTotal => 'Total diario';

  @override
  String get queryPresetMonthlyTotal => 'Total mensual';

  @override
  String get queryPresetCountPerDay => 'Conteo por día';

  @override
  String get queryPresetLatestValues => 'Últimos valores';

  @override
  String get queryBlockerOperand => 'Elige el campo a agregar.';

  @override
  String get queryBlockerCategoryOrPeriod =>
      'Elige el campo de categoría o de período.';

  @override
  String get queryBlockerAxes => 'Elige ambos ejes.';

  @override
  String get queryBlockerCategory => 'Elige el campo de categoría.';

  @override
  String get queryBlockerFilterValue =>
      'Ingresa el valor del filtro o quita el filtro.';

  @override
  String get queryMadeElsewhere =>
      'Creada en otro lugar; no se puede editar aquí.';

  @override
  String get queryAnExpression => 'una expresión';

  @override
  String queryDescAggregationOf(String aggregation, String field) {
    return '$aggregation de $field';
  }

  @override
  String queryDescSeries(String x, String y) {
    return 'cada registro, $x frente a $y';
  }

  @override
  String queryDescBy(String field) {
    return 'por $field';
  }

  @override
  String get queryDescPerDay => 'por día';

  @override
  String get queryDescPerWeek => 'por semana';

  @override
  String get queryDescPerMonth => 'por mes';

  @override
  String get queryDescPerYear => 'por año';

  @override
  String get queryDescFiltered => 'filtrada';

  @override
  String queryDescLimit(int limit) {
    return 'límite $limit';
  }

  @override
  String get queryDescEveryRecord => 'Todos los registros';

  @override
  String get queryAggCount => 'Conteo';

  @override
  String get queryAggSum => 'Suma';

  @override
  String get queryAggAverage => 'Promedio';

  @override
  String get queryAggMin => 'Mín.';

  @override
  String get queryAggMax => 'Máx.';

  @override
  String get queryGroupBy => 'Agrupar por';

  @override
  String get queryPeriodDay => 'Día';

  @override
  String get queryPeriodWeek => 'Semana';

  @override
  String get queryPeriodMonth => 'Mes';

  @override
  String get queryPeriodYear => 'Año';

  @override
  String get queryCategoryField => 'Campo de categoría';

  @override
  String get queryDateField => 'Campo de fecha';

  @override
  String get queryAggregation => 'Agregación';

  @override
  String get queryAggregationNeedsGroup =>
      'Elige un período en Agrupar por para agregar';

  @override
  String get queryOperandField => 'Campo a agregar';

  @override
  String get queryOutputScale => 'Escala de salida';

  @override
  String get queryRoundingPolicy => 'Política de redondeo';

  @override
  String get queryRoundingHalfEven => 'Mitad al par';

  @override
  String get queryRoundingRejectInexact => 'Rechazar inexactos';

  @override
  String get queryXAxis => 'Eje X';

  @override
  String get queryYAxis => 'Eje Y';

  @override
  String get queryFilterField => 'Campo';

  @override
  String get queryFilterOperator => 'Operador';

  @override
  String get queryFilterValue => 'Valor';

  @override
  String get queryOpEquals => 'es igual a';

  @override
  String get queryOpIsNot => 'no es';

  @override
  String get queryOpGreaterThan => 'mayor que';

  @override
  String get queryOpAtLeast => 'al menos';

  @override
  String get queryOpLessThan => 'menor que';

  @override
  String get queryOpAtMost => 'como máximo';

  @override
  String queryUsedBy(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'La usan $count widgets',
      one: 'La usa 1 widget',
      zero: 'No la usa ningún widget',
    );
    return '$_temp0';
  }

  @override
  String get queryNameRequired => 'Dale un nombre a la consulta.';

  @override
  String get queryName => 'Nombre de la consulta';

  @override
  String get queryNotEditable =>
      'Esta consulta se creó en otro lugar y no se puede editar aquí.';

  @override
  String get queryEditTitle => 'Editar consulta';

  @override
  String get querySaveAsNewTitle => 'Guardar como nueva consulta';

  @override
  String queryCopyName(String name) {
    return 'Copia de $name';
  }

  @override
  String get queryEditThis => 'Editar esta consulta';

  @override
  String get querySaveAsNew => 'Guardar como nueva';

  @override
  String get queryDefaultName => 'Consulta del widget';

  @override
  String get modelCardTitle => 'Modelos de voz';

  @override
  String get modelTagNotDownloaded => 'Sin descargar';

  @override
  String get modelTagDownloading => 'Descargando';

  @override
  String get modelTagReconnecting => 'Reconectando';

  @override
  String get modelTagVerifying => 'Verificando';

  @override
  String get modelTagPaused => 'En pausa';

  @override
  String get modelTagFailed => 'Falló';

  @override
  String get modelTagReady => 'Listo';

  @override
  String get modelRoleSpeech => 'Reconocimiento de voz';

  @override
  String get modelRoleUnderstanding => 'Comprensión';

  @override
  String get modelRoleSpeechInSentence => 'reconocimiento de voz';

  @override
  String get modelRoleUnderstandingInSentence => 'comprensión';

  @override
  String get modelAllLanguages => 'Todos los idiomas';

  @override
  String modelSummaryTotal(String language, String total) {
    return '$language · $total en total';
  }

  @override
  String modelSummaryProgress(String language, String done, String total) {
    return '$language · $done de $total';
  }

  @override
  String modelSummarySize(String language, String total) {
    return '$language · $total';
  }

  @override
  String modelSummaryPaused(String language, String done, String total) {
    return '$language · en pausa en $done de $total';
  }

  @override
  String modelSummaryStopped(String language, String done) {
    return '$language · detenido en $done';
  }

  @override
  String modelSummaryCheckFailed(String language) {
    return '$language · falló la verificación';
  }

  @override
  String modelSummaryReady(String language, String total) {
    return '$language · $total usados en este teléfono';
  }

  @override
  String modelRowProgress(String stored, String size) {
    return '$stored de $size';
  }

  @override
  String get modelRowChecking => 'Verificando';

  @override
  String modelRowDamaged(String size) {
    return '$size · dañado';
  }

  @override
  String get modelWifiRecommended => 'Se recomienda Wi-Fi';

  @override
  String modelNeeds(String needed) {
    return 'Necesita $needed';
  }

  @override
  String modelNeedsWithFree(String needed, String free) {
    return 'Necesita $needed · $free libres en este teléfono';
  }

  @override
  String modelDownload(String size) {
    return 'Descargar $size';
  }

  @override
  String get modelPause => 'Pausar';

  @override
  String get modelResume => 'Reanudar';

  @override
  String get modelCancelAndDelete => 'Cancelar y eliminar';

  @override
  String modelPercent(int percent) {
    return '$percent %';
  }

  @override
  String modelTimeLeft(String time) {
    return 'unos $time';
  }

  @override
  String get modelReconnectingTitle => 'Se perdió la conexión — reconectando…';

  @override
  String get modelReconnectingResumes =>
      'La descarga continúa donde se detuvo.';

  @override
  String get modelReconnectingKeepOpen =>
      'Salir de Fi puede pausar la red. Mantenlo abierto para terminar más rápido.';

  @override
  String get modelVerifyingTitle => 'Verificando los datos descargados…';

  @override
  String get modelResumesFromHere => 'continúa desde aquí';

  @override
  String get modelNetworkTitle => 'Sin conexión';

  @override
  String get modelNetworkLine =>
      'No se pudo conectar con el servidor de descarga. Revisa tu Wi-Fi y reintenta. Los datos descargados se conservan.';

  @override
  String get modelStorageTitle => 'No hay suficiente espacio';

  @override
  String modelStorageLine(String needed) {
    return 'Libera $needed en este teléfono y reintenta.';
  }

  @override
  String get modelDamagedTitle => 'El archivo descargado está dañado';

  @override
  String modelDamagedLine(String role, String size) {
    return 'El modelo de $role no pasó la verificación. Reintentar lo descarga de nuevo ($size).';
  }

  @override
  String get modelIoTitle => 'No se pudo guardar la descarga';

  @override
  String get modelIoLine =>
      'Error de almacenamiento. Reintenta; los datos descargados se conservan.';

  @override
  String get modelCancelDialogTitle => '¿Cancelar la descarga?';

  @override
  String modelCancelDialogBody(String done) {
    return 'Se eliminarán los datos descargados ($done).';
  }

  @override
  String get modelCancelDialogConfirm => 'Cancelar descarga';

  @override
  String get modelCancelDialogKeep => 'Seguir descargando';

  @override
  String get modelDeleteDialogTitle => '¿Eliminar los modelos de voz?';

  @override
  String modelDeleteDialogBody(String size) {
    return 'Libera $size. El llenado por voz no funcionará hasta que los descargues de nuevo.';
  }

  @override
  String get modelKeepModels => 'Conservar modelos';

  @override
  String get modelRedownloadDialogTitle =>
      '¿Volver a descargar los modelos de voz?';

  @override
  String modelRedownloadDialogBody(String size) {
    return 'Los modelos se eliminan y se descargan de nuevo ($size).';
  }

  @override
  String get modelRedownloadDialogConfirm => 'Volver a descargar';

  @override
  String get modelOfferTitle => 'Descargar modelos de voz';

  @override
  String modelOfferLine(String language, String size) {
    return '$language · $size en total, una sola vez. Todo se procesa en este teléfono.';
  }

  @override
  String get modelOnMobileData => 'Usas datos móviles';

  @override
  String get modelOnWifi => 'Usas Wi-Fi';

  @override
  String get modelStorage => 'Almacenamiento';

  @override
  String modelFree(String size) {
    return '$size libres';
  }

  @override
  String get modelLater => 'Más tarde';

  @override
  String get modelDownloadingTitle => 'Descargando modelos de voz';

  @override
  String get modelReconnectingShort => 'Reconectando…';

  @override
  String get modelPausedTitle => 'Descarga en pausa';

  @override
  String modelProgressLine(String done, String total, int percent) {
    return '$done de $total · $percent %';
  }

  @override
  String get modelKeepFilling =>
      'Sigue llenando a mano. El micrófono se activa cuando esté listo.';

  @override
  String get modelPauseDownload => 'Pausar descarga';

  @override
  String get modelHide => 'Ocultar';

  @override
  String modelErrorLine(String title, String line) {
    return '$title. $line';
  }

  @override
  String get helpFieldRequiredTitle => 'Obligatorio';

  @override
  String get helpFieldRequiredBody =>
      'Un campo obligatorio debe tener un valor. Los registros nuevos no se pueden guardar sin él.\n\nActivarlo en un campo que los registros existentes no tienen marca esos registros como no válidos hasta que completes el campo. Nunca se eliminan, y aún puedes abrirlos y repararlos desde la lista de registros.\n\nDefinir un valor predeterminado lo evita: el valor predeterminado cuenta como el valor de cada registro que no tenga uno.';

  @override
  String get helpFieldDefaultTitle => 'Predeterminado';

  @override
  String get helpFieldDefaultBody =>
      'El valor que se usa cuando un registro no aporta uno. Completa los registros nuevos a medida que los creas y cumple la regla de Obligatorio para los registros existentes que no tienen el campo.\n\nDéjalo vacío si cada registro debe indicar su propio valor.';

  @override
  String get helpFieldDecimalScaleTitle => 'Escala decimal';

  @override
  String get helpFieldDecimalScaleBody =>
      'Cuántos dígitos se conservan después del separador decimal. La escala 2 guarda 10.25 exactamente; la escala 0 guarda solo números enteros.\n\nLos valores se guardan como números exactos, nunca en coma flotante, así que las sumas y los promedios no se desvían. La escala no se puede cambiar una vez que los registros tienen un valor en este campo.';

  @override
  String get helpFieldMinMaxTitle => 'Mínimo y máximo';

  @override
  String get helpFieldMinMaxBody =>
      'El rango en el que puede estar un valor, incluidos ambos extremos. Un registro fuera del rango se rechaza al guardarlo.\n\nDeja cualquiera de las casillas vacía para no poner límite de ese lado.';

  @override
  String get helpFieldMinMaxLengthTitle => 'Longitud mínima y máxima';

  @override
  String get helpFieldMinMaxLengthBody =>
      'Qué tan corto y qué tan largo puede ser el texto, contado en caracteres.\n\nDeja cualquiera de las casillas vacía para no poner límite de ese lado.';

  @override
  String get helpFieldMultilineTitle => 'Varias líneas';

  @override
  String get helpFieldMultilineBody =>
      'Muestra este campo de texto como un cuadro que acepta saltos de línea en lugar de una sola línea. Cambia cómo se edita el campo, no lo que se puede guardar en él.';

  @override
  String get helpFieldSliderTitle => 'Mostrar como control deslizante';

  @override
  String get helpFieldSliderBody =>
      'Muestra este campo numérico como un control deslizante que va del mínimo al máximo, con el valor elegido al lado. Mientras no se elija un valor, la pista no muestra el control; tócala o arrástrala para elegir uno, y el número aparece al lado.\n\nUna fila de números bajo la pista muestra la escala: cada paso cuando caben todos; si no, solo el mínimo y el máximo en los dos extremos.\n\nPaso define cuánto avanza cada movimiento, por ejemplo 10 en un rango de 0 a 100. Déjalo vacío para pasos enteros de 1. El paso debe dividir exactamente la distancia del mínimo al máximo, para que la última posición caiga en el máximo.\n\nSolo está disponible cuando hay un mínimo y un máximo definidos. Cambia cómo se edita el campo, no lo que se guarda: las consultas, los gráficos y la lista de registros siguen viendo un número.';

  @override
  String get helpWidgetTypeTitle => 'Tipo de widget';

  @override
  String get helpWidgetTypeBody =>
      'Lo que dibuja el widget.\n\nNúmero muestra un valor agregado, como un total o un conteo. Gráfico de líneas dibuja un valor a lo largo del tiempo. Gráfico de barras compara un valor entre categorías. Gráfico de dispersión coloca un punto por registro usando dos campos como ejes.';

  @override
  String get helpWidgetUseSavedQueryTitle => 'Usar una consulta guardada';

  @override
  String get helpWidgetUseSavedQueryBody =>
      'Activado, el widget reutiliza una consulta que ya guardaste, y editar esa consulta actualiza todos los widgets que la usan.\n\nDesactivado, construyes la consulta aquí y se guarda con el título del widget.';

  @override
  String get helpWidgetAggregationTitle => 'Agregación';

  @override
  String get helpWidgetAggregationBody =>
      'Cómo se reducen muchos registros a un solo número.\n\nConteo cuenta registros y no necesita campo. Suma, Promedio, Mín. y Máx. leen cada uno un campo numérico, elegido abajo.\n\nCon un período en Agrupar por, la agregación se calcula una vez por período en lugar de una sola vez sobre todo.';

  @override
  String get helpWidgetOperandFieldTitle => 'Campo a agregar';

  @override
  String get helpWidgetOperandFieldBody =>
      'El campo numérico que lee la agregación. Solo los campos de número, decimal y duración se pueden sumar o promediar.\n\nConteo lo ignora porque cuenta registros, no valores.';

  @override
  String get helpWidgetOutputScaleTitle => 'Escala de salida';

  @override
  String get helpWidgetOutputScaleBody =>
      'Cuántos decimales conserva el promedio. Un promedio rara vez da una división exacta, así que el resultado debe indicar su propia precisión en lugar de heredar una.';

  @override
  String get helpWidgetRoundingTitle => 'Política de redondeo';

  @override
  String get helpWidgetRoundingBody =>
      'Qué pasa cuando el promedio no cabe exactamente en la escala de salida.\n\nMitad al par redondea al valor más cercano y resuelve los empates hacia el dígito par, lo que evita sesgos en series largas de números. Rechazar inexacto se niega a mostrar un resultado en lugar de redondear, para que nunca leas un número redondeado como si fuera exacto.';

  @override
  String get helpWidgetGroupByTitle => 'Agrupar por';

  @override
  String get helpWidgetGroupByBody =>
      'Agrupa los registros por período de calendario (día, semana, mes o año) usando el campo de fecha que elijas, y calcula la agregación una vez por grupo. Cada grupo se convierte en un punto o una barra.\n\nElige Ninguno para agregar todo de una vez, o para agrupar por una categoría en lugar de un período.';

  @override
  String get helpWidgetDateFieldTitle => 'Campo de fecha';

  @override
  String get helpWidgetDateFieldBody =>
      'La fecha o marca de tiempo que decide en qué período cae un registro. Las semanas empiezan el lunes y los períodos se calculan en UTC.';

  @override
  String get helpWidgetCategoryFieldTitle => 'Campo de categoría';

  @override
  String get helpWidgetCategoryFieldBody =>
      'El campo cuyos valores se convierten en las categorías del eje: una barra o un punto por cada valor distinto. Los registros que comparten un valor se agregan juntos.';

  @override
  String get helpWidgetXAxisTitle => 'Eje X';

  @override
  String get helpWidgetXAxisBody =>
      'El campo que se grafica en horizontal, un punto por registro. No hay agregación: cada registro conserva su propio punto.';

  @override
  String get helpWidgetYAxisTitle => 'Eje Y';

  @override
  String get helpWidgetYAxisBody =>
      'El campo numérico que se grafica en vertical, un punto por registro.';

  @override
  String get helpWidgetFilterTitle => 'Filtro';

  @override
  String get helpWidgetFilterBody =>
      'Limita el widget a los registros que cumplen una condición, como monto mayor que 10 o categoría igual a Migraña.\n\nDeja el campo en Ninguno para incluir todos los registros. El filtro cambia lo que muestra el widget; nunca oculta ni elimina registros en ningún otro lugar.';

  @override
  String get helpWidgetUnitSuffixTitle => 'Sufijo de unidad';

  @override
  String get helpWidgetUnitSuffixBody =>
      'Texto que se muestra después del valor, como EUR o mg. Es solo de visualización: el número exacto no cambia y el sufijo nunca se guarda con los datos.';

  @override
  String get helpWidgetShowPointsTitle => 'Mostrar puntos';

  @override
  String get helpWidgetShowPointsBody =>
      'Dibuja un marcador en cada punto de datos de la línea, lo que ayuda cuando hay pocos puntos o cuando los huecos importan.';

  @override
  String get helpWidgetAxisLabelTitle => 'Etiqueta del eje Y';

  @override
  String get helpWidgetAxisLabelBody =>
      'Texto que se muestra junto al eje vertical para nombrar lo que se mide, como \"Horas\" o \"EUR\". Déjalo vacío para no mostrar etiqueta.';

  @override
  String get helpWidgetBarWidthTitle => 'Ancho de barra';

  @override
  String get helpWidgetBarWidthBody =>
      'Qué tan ancha se dibuja cada barra, en píxeles lógicos. Déjalo vacío para que el gráfico ajuste el tamaño de las barras.';

  @override
  String get helpWidgetPointRadiusTitle => 'Radio de punto';

  @override
  String get helpWidgetPointRadiusBody =>
      'Qué tan grande se dibuja cada punto, en píxeles lógicos. Déjalo vacío para el tamaño predeterminado.';

  @override
  String get helpComputedFieldsTitle => 'Campos calculados';

  @override
  String get helpComputedFieldsBody =>
      'Un campo calculado obtiene su valor de otros campos del mismo registro, como monto × tasa o fin − inicio. Se recalcula en este dispositivo cada vez que se lee, así que nunca está desactualizado, y solo se sincroniza su definición, nunca sus valores.\n\nÚsalo para totales sin signo, productos como precio × cantidad o el tiempo entre dos fechas. Las consultas y los widgets pueden usarlo como cualquier otro campo, y editarlo cambia todas las consultas y widgets que lo usan.';

  @override
  String get helpComputedFieldResultTitle => 'Tipo de resultado';

  @override
  String get helpComputedFieldResultBody =>
      'El tipo de resultado se deduce de la expresión; nunca lo eliges.\n\n+ y − necesitan que ambos lados tengan la misma cantidad de decimales. × suma los decimales de ambos lados (escala 2 × escala 3 da escala 5). Los números enteros y los decimales no se pueden mezclar en +, − o ×; convierte el número en decimal. Restar dos fechas da una duración.\n\n÷ siempre da un decimal con la escala que elijas. \"Redondear mitad al par\" redondea el último dígito; \"Rechazar inexacto\" deja el valor vacío cuando la respuesta no cabe exactamente.\n\nSi algún campo usado está vacío en un registro, el resultado está vacío para ese registro (\"puede estar vacío\").';

  @override
  String get helpQuerySavedQueriesTitle => 'Consultas guardadas';

  @override
  String get helpQuerySavedQueriesBody =>
      'Una consulta con nombre a la que pueden hacer referencia los widgets. Editarla aquí actualiza todos los widgets que la usan; el editor indica cuántos son antes de guardar.\n\nEliminar una consulta no elimina ningún registro.';

  @override
  String get helpPairingStartPairingTitle => 'Empezar a emparejar';

  @override
  String get helpPairingStartPairingBody =>
      'Hace que este dispositivo sea visible para los dispositivos cercanos durante un breve tiempo para que ambos intercambien confianza.\n\nAmbos dispositivos deben estar cerca y en la misma red, y ambos deben tener el emparejamiento activado. No se comparte nada hasta que confirmes el mismo código de seis dígitos en ambas pantallas.';

  @override
  String get helpPairingSingleInitiatorTitle =>
      'Solo un dispositivo se conecta';

  @override
  String get helpPairingSingleInitiatorBody =>
      'Ambos dispositivos se ven entre sí, pero solo uno puede tocar Conectar. Si ambos lo tocan, los dos intentos chocan y el emparejamiento falla.\n\nElige cualquiera de los dispositivos, toca Conectar ahí y deja que el otro espere.';

  @override
  String get helpDiscoverableTitle => 'Visible';

  @override
  String get helpDiscoverableBody =>
      'Cuando está activado, este dispositivo se anuncia a tus dispositivos emparejados en la red local y busca sus anuncios, para que se encuentren automáticamente.\n\nCuando está desactivado, ni se anuncia ni busca. Los dispositivos emparejados aún pueden conectarse mientras se conozca su dirección, por ejemplo una sesión que ya está abierta o una que llama a este dispositivo, pero un dispositivo cuya dirección cambió no se volverá a encontrar hasta que lo actives de nuevo.\n\nEmparejar un dispositivo nuevo no se ve afectado: usa su propio anuncio breve.';

  @override
  String get helpSyncEnabledTitle => 'Sincronizar con dispositivos emparejados';

  @override
  String get helpSyncEnabledBody =>
      'Cuando está activado, este dispositivo se conecta a tus dispositivos emparejados y mantiene los datos sincronizados con ellos.\n\nCuando está desactivado, la sincronización se pausa: las sesiones abiertas se cierran, este dispositivo deja de conectarse y se rechazan las conexiones de los dispositivos emparejados. Tus emparejamientos y datos se conservan, y los cambios se sincronizan de nuevo cuando lo vuelvas a activar.\n\nEmparejar un dispositivo nuevo sigue funcionando mientras la sincronización está pausada.';

  @override
  String helpAboutTooltip(String title) {
    return 'Acerca de $title';
  }

  @override
  String get bootResetLeadError =>
      'Esta versión de la app no puede abrir los datos locales de este dispositivo. Al restablecerlos podrás crear un conjunto de datos nuevo o unirte al de otro dispositivo.';

  @override
  String get recoveryResetLead =>
      'La recuperación necesita uno de tus otros dispositivos. Restablecer en su lugar abandona el conjunto de datos registrado en este dispositivo; si no tienes otro dispositivo que lo conserve, la copia apartada se guarda en el disco, pero esta app no puede leerla.';

  @override
  String get bootRetryAfterUnlock => 'Reintentar después de desbloquear';

  @override
  String get shellResetData => 'Restablecer los datos de este dispositivo';

  @override
  String get bootServiceUnavailable =>
      'El servicio local de colecciones no está disponible.';

  @override
  String get recoveryNeedsDevice => 'La recuperación necesita otro dispositivo';

  @override
  String get onboardQuarantined =>
      'Los datos encontrados en este dispositivo se apartaron porque faltaba su registro de conjunto de datos. No se eliminó nada: unirte al mismo conjunto de datos desde otro dispositivo los restaura.';

  @override
  String get onboardCreating => 'Creando…';

  @override
  String sidebarPairedSummary(int count, String reach) {
    return '$count emparejados · $reach';
  }

  @override
  String get sidebarNoneNearby => 'ninguno cerca';

  @override
  String sidebarConnectedCount(int count) {
    return '$count conectados';
  }

  @override
  String get devicesStatusOffline => 'Sin conexión';

  @override
  String get devicesStatusLooking => 'Buscando dispositivos emparejados';

  @override
  String get devicesStatusSearching => 'Buscando';

  @override
  String get devicesStatusConnected => 'Conectado';

  @override
  String get devicesStatusSyncing => 'Sincronizando';

  @override
  String get devicesStatusSynced => 'Sincronizado';

  @override
  String get devicesStatusError => 'Error';

  @override
  String get devicesStatusPaused => 'En pausa';

  @override
  String get devicesStatusRevoked => 'Revocado';

  @override
  String get devicesIntro =>
      'Los dispositivos en los que confías sincronizan este conjunto de datos directamente entre sí.';

  @override
  String devicesRotationError(String error) {
    return 'Se revocó el dispositivo, pero no se pudo rotar el secreto de descubrimiento: $error';
  }

  @override
  String get devicesRetryRotation => 'Reintentar rotación';

  @override
  String get devicesOtherDevice => 'el otro dispositivo';

  @override
  String devicesTrustedHeading(int count) {
    return 'Dispositivos de confianza · $count';
  }

  @override
  String get devicesPairDevice => 'Emparejar dispositivo';

  @override
  String get devicesThisDevice => 'Este dispositivo';

  @override
  String get devicesActions => 'Acciones del dispositivo';

  @override
  String get devicesRevokeUnpair => 'Revocar / desemparejar';

  @override
  String get devicesLogCopied => 'Registro copiado';

  @override
  String get devicesRenameTitle => 'Renombrar dispositivo';

  @override
  String devicesRevokeTitle(String name) {
    return '¿Revocar $name?';
  }

  @override
  String get devicesRevokeBody =>
      'Deja de sincronizar con este dispositivo de inmediato. Queda en la lista como revocado y puedes emparejarlo de nuevo más tarde.';

  @override
  String get devicesRevoke => 'Revocar';

  @override
  String get devicesDeleteTitle => '¿Eliminar el dispositivo revocado?';

  @override
  String devicesDeleteBody(String name) {
    return 'Quita $name de esta lista. Se puede emparejar de nuevo.';
  }

  @override
  String get devicesConnections => 'Conexiones';

  @override
  String get devicesDiscoverable => 'Visible';

  @override
  String get devicesDiscoverableSubtitle =>
      'Anuncia este dispositivo a los dispositivos emparejados en la red local.';

  @override
  String get devicesSyncEnabled => 'Sincronizar con dispositivos emparejados';

  @override
  String get devicesSyncEnabledSubtitle =>
      'Conéctate a dispositivos emparejados y acepta sus conexiones.';

  @override
  String get devicesNoneYet => 'Aún no hay dispositivos emparejados';

  @override
  String get devicesNoneBodyPhone =>
      'Inicia el emparejamiento en ambos dispositivos mientras estén cerca.';

  @override
  String get devicesNoneBody =>
      'Inicia el emparejamiento en ambos dispositivos mientras estén cerca. El emparejamiento se desactiva solo después de 2 minutos.';

  @override
  String devicesPairedBanner(String name) {
    return 'Emparejado con $name. La primera sincronización empieza automáticamente.';
  }

  @override
  String get devicesPairAnother => 'Emparejar otro';

  @override
  String get devicesDismiss => 'Descartar';

  @override
  String get devicesNetworkingMissing => 'La red no está configurada';

  @override
  String get devicesIdCopied => 'ID copiado';

  @override
  String get devicesCopyId => 'Copiar ID';

  @override
  String get devicesResetBody =>
      'Abandona aquí el conjunto de datos para crear uno nuevo o unirte al de otro dispositivo. Se conserva la identidad de tu dispositivo.';

  @override
  String get devicesFactState => 'Estado';

  @override
  String get devicesFactEndpoint => 'Dirección';

  @override
  String get devicesFactLastAttempt => 'Último intento';

  @override
  String get devicesFactSyncPort => 'Puerto de sincronización';

  @override
  String get devicesNotBound => 'sin asignar';

  @override
  String get devicesReconnect => 'Reconectar';

  @override
  String get devicesCopyLog => 'Copiar registro';

  @override
  String devicesLogHeading(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count eventos',
      one: '1 evento',
    );
    return 'Registro de conexión · $_temp0';
  }

  @override
  String get devicesLogAll => 'Todo';

  @override
  String get devicesLogPairing => 'Emparejamiento';

  @override
  String get devicesLogPeer => 'Par';

  @override
  String get devicesNoEvents => 'Sin eventos.';

  @override
  String get pairingTitle => 'Emparejar un dispositivo';

  @override
  String get pairingIdleBody =>
      'El emparejamiento está desactivado. Inícialo solo cuando ambos dispositivos estén cerca.';

  @override
  String get pairingStart => 'Iniciar emparejamiento';

  @override
  String get pairingDiscoveryOffNote =>
      'La visibilidad está desactivada — el emparejamiento sigue funcionando.';

  @override
  String get pairingAlreadyPaired =>
      'Todos los dispositivos cercanos ya están emparejados.';

  @override
  String get pairingNoCandidates =>
      'Aún no hay dispositivos cercanos para emparejar.';

  @override
  String get pairingConnect => 'Conectar';

  @override
  String get pairingStop => 'Detener';

  @override
  String get pairingConnecting => 'Conectando de forma segura…';

  @override
  String get pairingSuccess => 'Dispositivo emparejado correctamente.';

  @override
  String get pairingAnother => 'Emparejar otro dispositivo';

  @override
  String get pairingDifferentDevice => 'Emparejar otro dispositivo distinto';

  @override
  String get pairingKeyringLocked =>
      'Tu llavero de inicio de sesión está bloqueado, así que este dispositivo no pudo guardar el emparejamiento. Desbloquea el llavero y vuelve a intentarlo; es posible que el otro dispositivo ya muestre este como emparejado.';

  @override
  String get pairingResetLead =>
      'Para unirte al conjunto de datos del otro dispositivo, primero hay que restablecer los datos locales de este.';

  @override
  String get resetTitle => '¿Restablecer los datos de este dispositivo?';

  @override
  String resetTrustedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Se conservan $count dispositivos de confianza y se pueden emparejar de nuevo.',
      one:
          'Se conserva 1 dispositivo de confianza y se puede emparejar de nuevo.',
      zero: 'No hay dispositivos de confianza registrados.',
    );
    return '$_temp0';
  }

  @override
  String get resetConfirm => 'Restablecer datos';

  @override
  String get fieldTypeText => 'Texto';

  @override
  String get fieldTypeInteger => 'Entero';

  @override
  String get fieldTypeDecimal => 'Decimal';

  @override
  String get fieldTypeBoolean => 'Booleano';

  @override
  String get fieldTypeDate => 'Fecha';

  @override
  String get fieldTypeDateTime => 'Fecha y hora';

  @override
  String get fieldTypeDuration => 'Duración';

  @override
  String get fieldTypeChoice => 'Opción';

  @override
  String get inputTrue => 'Verdadero';

  @override
  String get inputFalse => 'Falso';

  @override
  String get inputPickDate => 'Elige una fecha';

  @override
  String get inputPickDateTime => 'Elige fecha y hora';

  @override
  String get inputToday => 'Hoy';

  @override
  String get inputNow => 'Ahora';

  @override
  String get inputEmpty => 'Vacío';

  @override
  String get collectionsDuplicate => 'Duplicar';

  @override
  String get collectionsImportCsv => 'Importar CSV…';

  @override
  String get collectionsExportCsv => 'Exportar CSV';

  @override
  String get collectionsExportJson => 'Exportar JSON';

  @override
  String get collectionsDeleteEllipsis => 'Eliminar…';

  @override
  String get collectionsSortLastEdited => 'Última edición';

  @override
  String get collectionsSortName => 'Nombre';

  @override
  String get collectionsSort => 'Ordenar';

  @override
  String get collectionsTitle => 'Colecciones';

  @override
  String get collectionsImportExport => 'Importar y exportar';

  @override
  String get collectionsImportJson => 'Importar JSON…';

  @override
  String get collectionsExportAll => 'Exportar todo';

  @override
  String get collectionsExportSelected => 'Exportar selección…';

  @override
  String get collectionsNewCollection => 'Nueva colección';

  @override
  String get collectionsEmpty =>
      'Crea una colección para empezar a dar forma a tus datos.';

  @override
  String collectionsRecordCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count registros',
      one: '1 registro',
    );
    return '$_temp0';
  }

  @override
  String collectionsFieldCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count campos',
      one: '1 campo',
    );
    return '$_temp0';
  }

  @override
  String collectionsIncomplete(int count) {
    return '$count incompletos';
  }

  @override
  String collectionsEditedLower(String time) {
    return 'editada $time';
  }

  @override
  String get collectionsActions => 'Acciones de la colección';

  @override
  String collectionsExportedTo(String name) {
    return 'Exportado a $name';
  }

  @override
  String get collectionsExportTitle => 'Exportar colecciones';

  @override
  String collectionsDeleteTitle(String name) {
    return '¿Eliminar \"$name\"?';
  }

  @override
  String get collectionsDeleteGeneric =>
      'Sus registros, widgets y consultas guardadas se eliminan con ella.';

  @override
  String get collectionsRenameTitle => 'Renombrar colección';

  @override
  String get collectionsDescription => 'Descripción';

  @override
  String collectionsCopyName(String name) {
    return '$name (copia)';
  }

  @override
  String collectionsContentsRecords(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count registros',
      one: '1 registro',
    );
    return '$_temp0';
  }

  @override
  String collectionsContentsWidgets(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count widgets',
      one: '1 widget',
    );
    return '$_temp0';
  }

  @override
  String collectionsContentsSavedQueries(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count consultas guardadas',
      one: '1 consulta guardada',
    );
    return '$_temp0';
  }

  @override
  String get collectionsContentsEmpty => 'Esta colección está vacía.';

  @override
  String collectionsContentsJoin(String list, String last) {
    return '$list y $last';
  }

  @override
  String collectionsContentsDeleted(int total, String list) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$list se eliminan con ella.',
      one: '$list se elimina con ella.',
    );
    return '$_temp0';
  }

  @override
  String get recordsBackToCollections => 'Volver a colecciones';

  @override
  String get recordsBreadcrumb => 'Colecciones  /';

  @override
  String get recordsSchema => 'Esquema';

  @override
  String get recordsQueries => 'Consultas';

  @override
  String get recordsSelect => 'Seleccionar';

  @override
  String get recordsNewRecord => 'Nuevo registro';

  @override
  String get recordsMoreActions => 'Más acciones';

  @override
  String get recordsSelectRecords => 'Seleccionar registros';

  @override
  String get recordsCollectionActions => 'Acciones de la colección…';

  @override
  String get recordsSection => 'Registros';

  @override
  String get recordsNewestFirst => 'Más recientes primero';

  @override
  String get recordsEmpty => 'Aún no hay registros.';

  @override
  String get recordsFab => 'Registro';

  @override
  String recordsMoreFields(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '+ $count campos más',
      one: '+ 1 campo más',
    );
    return '$_temp0';
  }

  @override
  String get recordsIncomplete => 'Incompleto';

  @override
  String get recordsDeleteRecord => 'Eliminar registro';

  @override
  String get recordsSchemaTitle => 'Esquema de la colección';

  @override
  String get recordsReorderPhone => 'Mantén presionado para reordenar';

  @override
  String get recordsReorderDesktop =>
      'Arrastra para reordenar · haz clic en un campo para editarlo';

  @override
  String get recordsAddField => 'Agregar campo';

  @override
  String recordsComputedNewer(String version) {
    return 'Creado por una versión más nueva (expresión v$version); no se puede editar aquí';
  }

  @override
  String get recordsComputedUnsupported =>
      'Usa operaciones que este editor no ofrece; no se puede editar aquí';

  @override
  String get recordsMayBeEmpty => 'puede estar vacío';

  @override
  String get recordsEditComputed => 'Editar campo calculado';

  @override
  String get recordsRemoveComputed => 'Quitar campo calculado';

  @override
  String get recordsComputedSheetTitle => 'Campos calculados y consultas';

  @override
  String get recordsComputedFields => 'Campos calculados';

  @override
  String get recordsComputedFieldsHint =>
      'Se calculan por registro a partir de otros campos.';

  @override
  String get recordsAddComputed => 'Agregar campo calculado';

  @override
  String get recordsSavedQueries => 'Consultas guardadas';

  @override
  String get recordsSavedQueriesHint =>
      'Agregados sobre los registros. Los widgets pueden reutilizarlos.';

  @override
  String get recordsEditQuery => 'Editar consulta';

  @override
  String get recordsRemoveQuery => 'Quitar consulta';

  @override
  String recordsUsedBy(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'la usan $count widgets',
      one: 'la usa 1 widget',
      zero: 'no la usa ningún widget',
    );
    return '$_temp0';
  }

  @override
  String recordsSelected(int count) {
    return '$count seleccionados';
  }

  @override
  String recordsInCollection(String name) {
    return 'en $name';
  }

  @override
  String get recordsSelectAll => 'Seleccionar todo';

  @override
  String get recordsEditField => 'Editar campo';

  @override
  String recordsBatchDeleteTitle(int count) {
    return '¿Eliminar $count registros?';
  }

  @override
  String get recordsBatchDeleteBody =>
      'Todos los registros seleccionados se eliminan en un solo paso.';

  @override
  String recordsDeletedSnack(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Se eliminaron $count registros',
      one: 'Se eliminó 1 registro',
    );
    return '$_temp0';
  }

  @override
  String recordsBatchSetTitle(String field, int count) {
    return '¿Establecer $field en $count registros?';
  }

  @override
  String get recordsBatchSetBody =>
      'Todos los registros seleccionados se actualizan en un solo paso.';

  @override
  String recordsBatchEditTitle(int count) {
    return 'Editar campo en $count registros';
  }

  @override
  String get recordsField => 'Campo';

  @override
  String get recordsContinue => 'Continuar';

  @override
  String get recordDiscardTitle => '¿Descartar este registro?';

  @override
  String get recordDiscardBody =>
      'El procesamiento de voz se detendrá y se perderán los campos que cambiaste.';

  @override
  String get recordDiscard => 'Descartar';

  @override
  String get recordKeepEditing => 'Seguir editando';

  @override
  String get recordDeleteTitle => '¿Eliminar este registro?';

  @override
  String get recordDeleteBody => 'Se quita de la colección.';

  @override
  String recordCreated(String date) {
    return 'creado el $date';
  }

  @override
  String get recordEditTitle => 'Editar registro';

  @override
  String recordTitleNeeded(String title, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'faltan $count campos',
      one: 'falta 1 campo',
    );
    return '$title · $_temp0';
  }

  @override
  String get recordFooterHint => '* Obligatorio · Ctrl+Enter para guardar';

  @override
  String get recordDeleteRecordEllipsis => 'Eliminar registro…';

  @override
  String get recordSave => 'Guardar registro';

  @override
  String get recordSaveChanges => 'Guardar cambios';

  @override
  String get recordScrollMore => 'Desplázate para ver más columnas →';

  @override
  String recordIncompleteLead(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'A $count registros les falta un campo obligatorio',
      one: 'A 1 registro le falta un campo obligatorio',
    );
    return '$_temp0';
  }

  @override
  String recordTapToFinish(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Toca uno para terminar.',
      one: 'Tócalo para terminar.',
    );
    return '$_temp0';
  }

  @override
  String recordClickToFinish(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Haz clic en uno para terminar.',
      one: 'Haz clic en él para terminar.',
    );
    return '$_temp0';
  }

  @override
  String formCouldntSave(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'No se pudo guardar. $count campos necesitan atención.',
      one: 'No se pudo guardar. 1 campo necesita atención.',
    );
    return '$_temp0';
  }

  @override
  String formRequiredSemantics(String name) {
    return '$name, obligatorio';
  }

  @override
  String get formRequiredLegend => ' obligatorio';

  @override
  String get formNeeded => 'Necesario para completar este registro';

  @override
  String get widgetDashboard => 'Panel';

  @override
  String get widgetReorder => 'Reordenar';

  @override
  String get widgetAdd => 'Agregar widget';

  @override
  String get widgetEdit => 'Editar widget';

  @override
  String get widgetEmptyDashboard =>
      'Aún no hay widgets. Agrega uno para resumir esta colección.';

  @override
  String widgetAllRecords(String description) {
    return '$description · todos los registros';
  }

  @override
  String get widgetTitleRequired => 'Dale un título al widget.';

  @override
  String get widgetSavedQueryRequired => 'Elige una consulta guardada.';

  @override
  String get widgetType => 'Tipo de widget';

  @override
  String widgetTypeValue(String type) {
    return 'Tipo de widget: $type';
  }

  @override
  String get widgetUnsupportedNotice =>
      'Esta versión no puede mostrar este widget. El título, la consulta, el tamaño y el orden siguen siendo editables y su configuración se conserva intacta.';

  @override
  String get widgetTitle => 'Título';

  @override
  String get widgetUseSavedQuery => 'Usar una consulta guardada';

  @override
  String get widgetSavedQuery => 'Consulta guardada';

  @override
  String get widgetPresentation => 'Presentación';

  @override
  String widgetConfigVersionPreserved(String version) {
    return 'La versión de configuración $version se conserva tal cual.';
  }

  @override
  String get widgetSize => 'Tamaño';

  @override
  String get widgetSizeFull => 'Completo';

  @override
  String get widgetRemove => 'Quitar';

  @override
  String get widgetRemoveTooltip => 'Quitar widget';

  @override
  String get widgetUntitled => 'Sin título';

  @override
  String get widgetPreview => 'Vista previa';

  @override
  String get widgetChooseData => 'Elige los datos a mostrar';

  @override
  String get widgetSizeSmallHint => 'Pequeño ocupa 1 de 4 columnas.';

  @override
  String get widgetSizeMediumHint => 'Mediano ocupa 2 de 4 columnas.';

  @override
  String get widgetSizeLargeHint => 'Grande ocupa 3 de 4 columnas.';

  @override
  String get widgetSizeFullHint => 'Completo ocupa las 4 columnas.';

  @override
  String get widgetUnitSuffix => 'Sufijo de unidad (opcional)';

  @override
  String get widgetUnitSuffixHelper =>
      'Se muestra después del valor exacto, por ejemplo \"EUR\".';

  @override
  String get widgetShowPoints => 'Mostrar puntos';

  @override
  String get widgetYAxisLabel => 'Etiqueta del eje Y (opcional)';

  @override
  String get widgetBarWidth => 'Ancho de barra (opcional)';

  @override
  String get widgetPointRadius => 'Radio de punto (opcional)';

  @override
  String get widgetTypeAggregateNumber => 'Número agregado';

  @override
  String get widgetTypeLineChart => 'Gráfico de líneas';

  @override
  String get widgetTypeBarChart => 'Gráfico de barras';

  @override
  String get widgetTypeScatterPlot => 'Gráfico de dispersión';

  @override
  String get voiceFillByVoice => 'Llenar por voz';

  @override
  String get voiceTipLine =>
      'Toca el micrófono de abajo y di los detalles. Los revisas antes de guardar.';

  @override
  String get voiceDismissTip => 'Descartar consejo';

  @override
  String get voicePrimerTitle => 'Habla para llenar registros';

  @override
  String get voicePrivacyLine =>
      'El audio se procesa en este dispositivo y nunca se guarda.';

  @override
  String get voicePrimerNext =>
      'A continuación, Android pedirá acceso al micrófono.';

  @override
  String get voiceNotNow => 'Ahora no';

  @override
  String get voiceContinue => 'Continuar';

  @override
  String get voiceDownloadProgressLabel => 'Progreso de la descarga';

  @override
  String get voiceListening => 'Escuchando';

  @override
  String voiceTry(String example) {
    return 'Prueba: «$example»';
  }

  @override
  String get voiceListeningHint =>
      'Toca detener al terminar, o mantén presionado el micrófono para hablar';

  @override
  String get voiceFillingFields => 'Llenando campos';

  @override
  String get voiceTranscribing => 'Transcribiendo';

  @override
  String get voiceTranscribed => 'Transcrito';

  @override
  String get voiceTranscribingStep => 'Transcribiendo…';

  @override
  String get voiceFillingFieldsStep => 'Llenando campos…';

  @override
  String get voiceUsuallySeconds => 'Suele tardar 4–8 segundos';

  @override
  String get voiceHeard => 'Escuchado';

  @override
  String voiceQuotedTranscript(String transcript) {
    return '«$transcript»';
  }

  @override
  String get voiceHeardCaps => 'ESCUCHADO';

  @override
  String get voiceWhatWasHeard => 'Lo que se escuchó';

  @override
  String get voiceClearField => 'Borrar campo';

  @override
  String get voiceOrdinalFirst => '1.º';

  @override
  String get voiceOrdinalSecond => '2.º';

  @override
  String get voiceOrdinalThird => '3.º';

  @override
  String voiceOrdinalOther(int n) {
    return '$n.º';
  }

  @override
  String voiceFilledCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Se llenaron $count campos',
      one: 'Se llenó 1 campo',
    );
    return '$_temp0';
  }

  @override
  String get voiceCheckThenSave => 'Revisa los campos y guarda.';

  @override
  String get voiceSpeakAgain => 'Hablar de nuevo';

  @override
  String voiceRound(int round, int max) {
    return '$round de $max';
  }

  @override
  String voiceNeedLine(String filled) {
    return '$filled. Di el resto o escribe en los campos marcados.';
  }

  @override
  String get voiceAnswerByVoice => 'Responder por voz';

  @override
  String voiceCouldntGet(String fields) {
    return 'No se pudo obtener: $fields';
  }

  @override
  String get voiceExhaustedLine =>
      'Escríbelo en el campo marcado y guarda. El micrófono sigue funcionando si quieres intentarlo de nuevo.';

  @override
  String voiceUpdated(String fields) {
    return 'Se actualizó: $fields';
  }

  @override
  String get voiceSpeaking => 'Hablando';

  @override
  String get voiceMute => 'Silenciar respuestas habladas';

  @override
  String get voiceDismiss => 'Descartar';

  @override
  String get voiceOpenSettings => 'Abrir ajustes';

  @override
  String get voiceSettings => 'Ajustes';

  @override
  String get voiceErrorNoSpeechTitle => 'No se escuchó nada';

  @override
  String get voiceErrorNoSpeechLine =>
      'Revisa que el micrófono no esté tapado e inténtalo de nuevo.';

  @override
  String get voiceErrorNothingMatchedTitle => 'No hubo coincidencias';

  @override
  String get voiceErrorNothingMatchedLine =>
      'No pude relacionar nada con los campos de esta colección. Prueba nombrar un campo, como “monto 12.50”.';

  @override
  String get voiceErrorPermissionDeniedTitle =>
      'El acceso al micrófono está desactivado';

  @override
  String get voiceErrorPermissionDeniedLine =>
      'Permite el acceso al micrófono en los ajustes de Android para llenar por voz. Puedes seguir escribiendo.';

  @override
  String get voiceErrorMicBusyTitle => 'El micrófono está ocupado';

  @override
  String get voiceErrorMicBusyLine =>
      'Otra app está usando el micrófono. Ciérrala e inténtalo de nuevo.';

  @override
  String get voiceErrorModelLoadFailedTitle =>
      'No se pudo cargar el modelo de voz';

  @override
  String get voiceErrorModelLoadFailedLine =>
      'El archivo del modelo puede estar dañado. Reintenta o vuelve a descargarlo en Ajustes.';

  @override
  String get voiceErrorLowMemoryTitle => 'No hay suficiente memoria';

  @override
  String get voiceErrorLowMemoryLine =>
      'Cierra otras apps e inténtalo de nuevo. Tu formulario se conserva.';

  @override
  String get voiceErrorInterruptedBackgroundTitle => 'La grabación se detuvo';

  @override
  String get voiceErrorInterruptedBackgroundLine =>
      'Fi pasó a segundo plano, así que la grabación se detuvo. No se conservó nada.';

  @override
  String get voiceErrorInterruptedCallTitle => 'Se detuvo por una llamada';

  @override
  String get voiceErrorInterruptedCallLine =>
      'La grabación se detuvo al entrar una llamada. No se conservó nada.';

  @override
  String get voiceErrorCancelledTitle => 'Detenido';

  @override
  String get voiceErrorCancelledLine => 'No se conservó nada.';

  @override
  String get voiceMicStopListening => 'Dejar de escuchar';

  @override
  String get voiceMicProcessing => 'Procesando la voz';

  @override
  String voiceMicDownloading(int percent) {
    return 'Descargando el modelo de voz, $percent por ciento';
  }

  @override
  String get settingsTitle => 'Ajustes';

  @override
  String get settingsSubtitle => 'Preferencias para esta computadora.';

  @override
  String get settingsVoiceInput => 'Entrada de voz';

  @override
  String get settingsMicrophone => 'Micrófono';

  @override
  String get settingsAbout => 'Acerca de';

  @override
  String get settingsVersion => 'Versión';

  @override
  String get settingsNetwork => 'Red';

  @override
  String settingsNetworkSummary(int first, int last, int mdns) {
    return 'Red local y tailnet · UDP $first–$last · mDNS $mdns';
  }

  @override
  String get settingsMicAccess => 'Acceso al micrófono';

  @override
  String get settingsMicAllowed => 'Permitido';

  @override
  String get settingsMicNotAllowed => 'Aún no permitido';

  @override
  String get settingsMicAsksFirst =>
      'Fi lo pide la primera vez que usas la voz.';

  @override
  String get settingsMicOff => 'Desactivado';

  @override
  String get settingsMicTurnOn =>
      'Actívalo en los ajustes de Android para llenar por voz.';

  @override
  String get settingsMicUnknown => 'Desconocido';

  @override
  String get settingsAndroidSettings => 'Ajustes de Android';

  @override
  String get settingsHandsFree => 'Respuestas habladas manos libres';

  @override
  String get settingsHandsFreeDetail =>
      'Dice la pregunta de “falta” y una confirmación breve';

  @override
  String settingsNotEnoughStorage(String size) {
    return 'No hay suficiente espacio: se necesitan $size.';
  }

  @override
  String get settingsFinishVoiceFirst =>
      'Primero termina el llenado por voz en curso.';

  @override
  String get settingsCouldntChangeModels =>
      'No se pudieron cambiar los modelos de voz. Inténtalo de nuevo.';

  @override
  String get fieldEditorChipMultiline => 'Varias líneas';

  @override
  String get fieldEditorChipLengthLimits => 'Límites de longitud';

  @override
  String get fieldEditorChipRange => 'Rango';

  @override
  String get fieldEditorChipSlider => 'Mostrar como control deslizante';

  @override
  String get fieldEditorChipDateRange => 'Rango de fechas';

  @override
  String get fieldEditorChipDefaultValue => 'Valor predeterminado';

  @override
  String get fieldEditorSummaryMultiline => 'varias líneas';

  @override
  String fieldEditorSummaryScale(int scale) {
    return '$scale dec.';
  }

  @override
  String fieldEditorAtLeast(int min) {
    return 'al menos $min';
  }

  @override
  String fieldEditorAtMost(int max) {
    return 'como máximo $max';
  }

  @override
  String fieldEditorTurnOff(String option) {
    return 'Desactivar $option';
  }

  @override
  String get fieldEditorStepPositive =>
      'El paso debe ser un número entero positivo';

  @override
  String get fieldEditorStepDivides => 'El paso debe dividir el rango.';

  @override
  String get helpGotIt => 'Entendido';

  @override
  String get fieldSummarySlider => 'control deslizante';

  @override
  String fieldEditorDefaultExactLength(int min) {
    return 'El valor predeterminado debe tener exactamente $min caracteres.';
  }

  @override
  String fieldEditorDefaultLengthBetween(int min, int max) {
    return 'El valor predeterminado debe tener entre $min y $max caracteres.';
  }

  @override
  String fieldEditorDefaultMinLength(int min) {
    return 'El valor predeterminado debe tener al menos $min caracteres.';
  }

  @override
  String fieldEditorDefaultMaxLength(int max) {
    return 'El valor predeterminado debe tener como máximo $max caracteres.';
  }

  @override
  String fieldEditorDefaultBetween(String low, String high) {
    return 'El valor predeterminado debe estar entre $low y $high.';
  }

  @override
  String fieldEditorDefaultAtLeast(String low) {
    return 'El valor predeterminado debe ser al menos $low.';
  }

  @override
  String fieldEditorDefaultAtMost(String high) {
    return 'El valor predeterminado debe ser como máximo $high.';
  }

  @override
  String fieldEditorMakeRequiredTitle(String name) {
    return '¿Hacer obligatorio “$name”?';
  }

  @override
  String fieldEditorMakeRequiredBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count registros no tienen valor y se marcarán como incompletos.',
      one: '1 registro no tiene valor y se marcará como incompleto.',
    );
    return '$_temp0';
  }

  @override
  String get fieldEditorMakeRequired => 'Hacer obligatorio';

  @override
  String get fieldEditorKeepOptional => 'Dejar opcional';

  @override
  String fieldEditorDeleteOptionTitle(String label) {
    return '¿Eliminar la opción “$label”?';
  }

  @override
  String fieldEditorDeleteOptionBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count registros la usan y la conservan. No se puede elegir en registros nuevos.',
      one:
          '1 registro la usa y la conserva. No se puede elegir en registros nuevos.',
    );
    return '$_temp0';
  }

  @override
  String get fieldEditorKeepOption => 'Conservar opción';

  @override
  String get fieldEditorNewField => 'Nuevo campo';

  @override
  String get fieldEditorName => 'Nombre';

  @override
  String get fieldEditorNameHint => 'p. ej. nota';

  @override
  String get fieldEditorType => 'Tipo';

  @override
  String get fieldEditorDecimalScale => 'Escala decimal';

  @override
  String get fieldEditorSliderNeedsRange =>
      'Mostrar como control deslizante necesita un rango con ambos extremos.';

  @override
  String get fieldEditorAddField => 'Agregar campo';

  @override
  String get fieldEditorSaveField => 'Guardar campo';

  @override
  String get fieldEditorDeleteField => 'Eliminar campo';

  @override
  String fieldEditorDeleteFieldTitle(String name) {
    return '¿Eliminar el campo “$name”?';
  }

  @override
  String fieldEditorDeleteFieldBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Quita el campo del esquema. $count registros pierden su valor.',
      one: 'Quita el campo del esquema. 1 registro pierde su valor.',
      zero: 'Quita el campo del esquema.',
    );
    return '$_temp0';
  }

  @override
  String get fieldEditorKeepField => 'Conservar campo';

  @override
  String fieldEditorDeleteFieldNamed(String name) {
    return 'Eliminar campo $name';
  }

  @override
  String fieldEditorRequiredWarning(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count registros no tienen valor en este campo y se marcarán como incompletos.',
      one:
          '1 registro no tiene valor en este campo y se marcará como incompleto.',
    );
    return '$_temp0';
  }

  @override
  String get fieldEditorMinCharacters => 'Mín. de caracteres';

  @override
  String get fieldEditorMaxCharacters => 'Máx. de caracteres';

  @override
  String get fieldEditorEarliest => 'Más temprana';

  @override
  String get fieldEditorLatest => 'Más tardía';

  @override
  String get fieldEditorMinimum => 'Mínimo';

  @override
  String get fieldEditorMaximum => 'Máximo';

  @override
  String get fieldEditorStepOptional => 'Paso (opcional)';

  @override
  String get fieldEditorDate => 'Fecha';

  @override
  String get fieldEditorDefault => 'Predeterminado';

  @override
  String get fieldEditorDayOfCreation => 'Día de creación';

  @override
  String get fieldEditorFixedDate => 'Fecha fija';

  @override
  String get fieldEditorDays => 'días';

  @override
  String fieldEditorOptionsCount(int count) {
    return 'Opciones · $count';
  }

  @override
  String get fieldEditorOptionFallback => 'opción';

  @override
  String get fieldEditorOptionLabel => 'Etiqueta de la opción';

  @override
  String get fieldEditorDeleteOption => 'Eliminar opción';

  @override
  String get fieldEditorAddOption => 'Agregar opción';

  @override
  String fieldEditorDeletedOptionNote(String example) {
    return 'Los registros que ya usan una opción eliminada la conservan. Se muestra como “$example (eliminada)” y no se puede elegir en registros nuevos.';
  }

  @override
  String fieldEditorFieldIn(String collection) {
    return 'Campo en $collection';
  }

  @override
  String get fieldEditorMore => 'Más';

  @override
  String widgetCouldNotRender(String error) {
    return 'No se pudo mostrar este widget: $error';
  }

  @override
  String get widgetUntitledWidget => 'Widget sin título';

  @override
  String get widgetUnsupported => 'Widget no compatible';

  @override
  String get widgetUnsupportedExplanation =>
      'Este widget lo creó otro dispositivo o una versión más reciente. Su configuración se conserva y se puede renombrar, reordenar o quitar.';

  @override
  String voiceKept(int count, String names) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Se conservaron tus cambios en $names.',
      one: 'Se conservó tu cambio en $names.',
    );
    return '$_temp0';
  }

  @override
  String get exprPickFieldIssue => 'Elige un campo.';

  @override
  String get exprWholeNumberIssue => 'Ingresa un número entero.';

  @override
  String exprDecimalsIssue(int scale) {
    return 'Ingresa un número con $scale decimales como máximo.';
  }

  @override
  String get exprTypeInteger => 'Entero';

  @override
  String exprTypeDecimal(int scale) {
    return 'Decimal, escala $scale';
  }

  @override
  String get exprTypeDuration => 'Duración';

  @override
  String get exprTypeDate => 'Fecha';

  @override
  String get exprTypeDateTime => 'Fecha y hora';

  @override
  String get exprTypeBoolean => 'Booleano';

  @override
  String get exprTypeText => 'Texto';

  @override
  String get exprTypeChoice => 'Opción';

  @override
  String get exprTypeEmpty => 'Vacío';

  @override
  String get exprSlotField => '¿campo?';

  @override
  String get exprSlotNumber => '¿número?';

  @override
  String exprTermsMissing(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Falta un valor en $count términos',
      one: 'Falta un valor en 1 término',
    );
    return '$_temp0';
  }

  @override
  String get exprResultInvalid =>
      'Resultado: no válido, revisa la parte resaltada';

  @override
  String get exprResultChecking => 'Resultado: comprobando…';

  @override
  String exprResultType(String type) {
    return 'Resultado: $type';
  }

  @override
  String exprResultTypeMaybeEmpty(String type) {
    return 'Resultado: $type · puede estar vacío';
  }

  @override
  String get exprResultUnknown => 'Resultado: desconocido';

  @override
  String get exprAbsoluteValue => 'Valor absoluto';

  @override
  String get exprAddOperator => 'Agregar operador';

  @override
  String get exprField => 'Campo';

  @override
  String get exprNumber => 'Número';

  @override
  String get exprFunction => 'Función';

  @override
  String get exprDivide => 'Dividir';

  @override
  String get exprAddTerm => 'Añadir término';

  @override
  String get exprDragTerm => 'Arrastra para reordenar';

  @override
  String get exprRemoveTerm => 'Quitar término';

  @override
  String exprCannotAdd(String right, String left) {
    return 'No se puede sumar $right a $left.';
  }

  @override
  String exprCannotSubtract(String right, String left) {
    return 'No se puede restar $right de $left.';
  }

  @override
  String exprCannotMultiply(String left, String right) {
    return 'No se puede multiplicar $left por $right.';
  }

  @override
  String exprCannotDivide(String left, String right) {
    return 'No se puede dividir $left entre $right.';
  }

  @override
  String get exprPickField => 'Elige un campo';

  @override
  String get exprWhole => 'Entero';

  @override
  String get exprRemoveOperator =>
      'Quitar operador (conservar el lado izquierdo)';

  @override
  String get exprScale => 'Escala';

  @override
  String get exprFewerDecimals => 'Menos decimales';

  @override
  String get exprMoreDecimals => 'Más decimales';

  @override
  String get exprRoundHalfEven => 'Redondear mitad al par';

  @override
  String get exprOf => 'de';

  @override
  String get exprRemoveAbsolute => 'Quitar valor absoluto';

  @override
  String get computedNewTitle => 'Nuevo campo calculado';

  @override
  String get computedEditTitle => 'Editar campo calculado';

  @override
  String computedInCollection(String collection) {
    return 'en $collection';
  }

  @override
  String get computedName => 'Nombre';

  @override
  String get computedNameHint => 'p. ej. diferencia';

  @override
  String inputDurationHint(String first, String second) {
    return 'p. ej. $first o $second';
  }

  @override
  String inputDurationUnparsed(String example) {
    return 'Usa unidades como $example';
  }

  @override
  String voiceStillNeed(String names) {
    return 'Todavía falta: $names';
  }

  @override
  String voiceSpokenFilled(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Se rellenaron $count campos.',
      one: 'Se rellenó 1 campo.',
    );
    return '$_temp0 Toca Guardar registro cuando quieras.';
  }

  @override
  String modelSpeechLabel(String language) {
    String _temp0 = intl.Intl.selectLogic(language, {
      'es': 'Whisper Base (español)',
      'other': 'Whisper Base (inglés)',
    });
    return '$_temp0';
  }

  @override
  String get modelOnThisPhone => 'En este teléfono';

  @override
  String modelOfferToDownload(String language, String size) {
    return '$language · $size por descargar, una sola vez. Todo se procesa en este teléfono.';
  }

  @override
  String modelMissingTag(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Faltan $count modelos',
      one: 'Falta 1 modelo',
    );
    return '$_temp0';
  }

  @override
  String modelSummaryToDownload(String language, String size) {
    return '$language · $size por descargar';
  }

  @override
  String get modelOtherLanguages => 'Otros idiomas';

  @override
  String get modelDeleteSpeechTitle => '¿Eliminar este modelo de voz?';

  @override
  String modelDeleteSpeechBody(String size, String language) {
    return 'Libera $size. La entrada de voz en $language no funcionará hasta que lo descargues de nuevo.';
  }

  @override
  String get modelKeepModel => 'Conservar modelo';

  @override
  String voiceNeedsSpeechModel(String language, String lang, String size) {
    String _temp0 = intl.Intl.selectLogic(lang, {
      'es': 'español',
      'other': 'inglés',
    });
    return 'Entrada de voz: $language — necesita el modelo de voz en $_temp0 ($size)';
  }

  @override
  String get langVoiceFollows => 'La entrada de voz sigue el idioma de la app';

  @override
  String langVoiceReady(String lang) {
    String _temp0 = intl.Intl.selectLogic(lang, {
      'es': 'español',
      'other': 'inglés',
    });
    return 'La entrada de voz sigue el idioma de la app · modelos en $_temp0 listos';
  }

  @override
  String langVoiceOfferTitle(String lang, String size) {
    String _temp0 = intl.Intl.selectLogic(lang, {
      'es': 'español',
      'other': 'inglés',
    });
    return 'Descargar modelo de voz en $_temp0 · $size';
  }

  @override
  String langVoiceOfferBody(String size) {
    return 'La entrada de voz sigue el idioma de la app. El modelo de comprensión ($size) ya está en este teléfono.';
  }

  @override
  String get langVoiceDownload => 'Descargar';

  @override
  String get peerNotReachable => 'No disponible';

  @override
  String get peerCantVerify => 'No se puede verificar';

  @override
  String get peerNotFound => 'No se encuentra en tu red';

  @override
  String get peerNoAnswer => 'No respondió en su última dirección';

  @override
  String get peerNotRecognized => 'Ya no reconoce este dispositivo';

  @override
  String peerLastSynced(String problem, String time) {
    return '$problem · Última sincronización $time';
  }

  @override
  String peerNeverSynced(String problem) {
    return '$problem · Nunca sincronizado';
  }

  @override
  String get peerGuidanceReach =>
      'Asegúrate de que ambos dispositivos estén en la misma red Wi-Fi y de que Fi esté abierto en el otro dispositivo. Fi sigue intentándolo por su cuenta.';

  @override
  String get peerGuidanceVerify =>
      'Es posible que el otro dispositivo se haya restablecido o haya desemparejado este. Vuelve a emparejar ambos dispositivos.';

  @override
  String get peerTryAgain => 'Intentar de nuevo';

  @override
  String get peerPairAgain => 'Emparejar de nuevo';

  @override
  String get peerConnectByAddress => 'Conectar por dirección…';

  @override
  String get connectAddressTitle => 'Conectar por dirección';

  @override
  String connectAddressLead(String name) {
    return 'Conéctate directamente con $name cuando no aparece en la red. Debe estar emparejado.';
  }

  @override
  String get connectAddressField => 'Dirección';

  @override
  String get connectAddressHelp =>
      'Encuéntrala en el otro dispositivo en Ajustes › Acerca de › Este dispositivo.';

  @override
  String get connectAddressConnect => 'Conectar';

  @override
  String get connectAddressConnecting => 'Conectando…';

  @override
  String connectAddressConnected(String name) {
    return 'Conectado a $name';
  }

  @override
  String get connectAddressInvalid =>
      'Escribe una dirección IPv4 como 192.168.0.165, opcionalmente seguida de :puerto.';

  @override
  String get connectAddressNotLocal =>
      'Usa una dirección de tu red local o tailnet, como 192.168.x.x o 100.x.x.x.';

  @override
  String connectAddressNoAnswer(String address) {
    return 'No hubo respuesta en $address. Revisa la dirección y que Fi esté abierto en el otro dispositivo.';
  }

  @override
  String connectAddressWrongDevice(String address, String name) {
    return 'El dispositivo en $address no es $name.';
  }

  @override
  String get connectAddressPaused =>
      'La sincronización con dispositivos emparejados está desactivada. Actívala para conectar.';

  @override
  String get aboutThisDevice => 'Este dispositivo';

  @override
  String get aboutNotOnLocalNetwork => 'Sin red local ni tailnet';

  @override
  String get aboutAddressCopied => 'Dirección copiada';

  @override
  String get aboutCopyAddress => 'Copiar dirección';

  @override
  String get devicesFailureCode => 'Código de error';

  @override
  String get aboutNetworkLan => 'LAN';

  @override
  String get aboutNetworkTailnet => 'Tailnet';

  @override
  String get modelRedownloadShort => 'Volver a descargar';

  @override
  String get modelDeleteShort => 'Eliminar';

  @override
  String get modelFailedTitle => 'Descarga fallida';

  @override
  String modelKeptLine(String done, String total) {
    return '$done de $total guardados';
  }

  @override
  String get modelReconnectingResumesLong =>
      'Se perdió la conexión: la descarga sigue donde se quedó.';

  @override
  String voiceListeningCap(int seconds) {
    return 'Se detiene solo tras $seconds segundos.';
  }

  @override
  String get collectionsClone => 'Clonar';

  @override
  String get collectionsCloneTitle => 'Clonar colección';

  @override
  String get collectionsCloneAction => 'Clonar';

  @override
  String get collectionsExportLine => 'Elige qué va en el archivo';

  @override
  String collectionsExportCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Exportar $count colecciones',
      one: 'Exportar 1 colección',
    );
    return '$_temp0';
  }

  @override
  String collectionsExportCountShort(int count) {
    return 'Exportar $count';
  }

  @override
  String get collectionsImportGroup => 'Importar';

  @override
  String get collectionsRenameHint => 'Intro para guardar · Esc para cancelar';

  @override
  String importPlaceRowColumn(int row, String column) {
    return 'fila $row, columna “$column”';
  }

  @override
  String get outcomeDismiss => 'Descartar';

  @override
  String get recordsNewValue => 'Nuevo valor';

  @override
  String get recordsNewValueHelp =>
      'Usa el mismo control que el formulario del registro.';

  @override
  String recordsSetField(String field) {
    return 'Establecer $field';
  }

  @override
  String get recordsKeepRecords => 'Mantener registros';

  @override
  String recordsSetSnack(String field, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Se estableció $field en $count registros',
      one: 'Se estableció $field en 1 registro',
    );
    return '$_temp0';
  }

  @override
  String issueDateMin(String date) {
    return 'Debe ser el $date o posterior';
  }

  @override
  String issueDateMax(String date) {
    return 'Debe ser el $date o anterior';
  }

  @override
  String get collectionsExport => 'Exportar';

  @override
  String importPlaceHeaderColumn(String column) {
    return 'el encabezado, columna “$column”';
  }

  @override
  String get widgetMenuTooltip => 'Acciones del widget';

  @override
  String get widgetMenuRemove => 'Quitar…';

  @override
  String widgetRemoveConfirmTitle(String title) {
    return '¿Quitar el widget «$title»?';
  }

  @override
  String get widgetRemoveConfirmBody =>
      'Su consulta guardada y los registros se conservan.';

  @override
  String get widgetKeep => 'Conservar widget';

  @override
  String get widgetMoveUp => 'Subir';

  @override
  String get widgetMoveDown => 'Bajar';

  @override
  String get widgetDragToReorder => 'Arrastra para reordenar';

  @override
  String get widgetNoRecordsMatch => 'Aún no hay registros que coincidan';

  @override
  String get widgetData => 'Datos';

  @override
  String get widgetDefineHere => 'Definir aquí';

  @override
  String get queryOnlyRecordsWhere => 'Solo registros donde';

  @override
  String get queryOpIs => 'es';

  @override
  String queryFilterChip(String field, String operator, String value) {
    return '$field $operator $value';
  }

  @override
  String get queryAddFilter => 'Agregar filtro';

  @override
  String get queryRemoveFilter => 'Quitar filtro';

  @override
  String get recordsAddQuery => 'Agregar consulta';

  @override
  String get queryNewTitle => 'Nueva consulta';

  @override
  String queryUsedByApplies(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Usada por $count widgets · los cambios también se aplican allí',
      one: 'Usada por 1 widget · los cambios también se aplican allí',
    );
    return '$_temp0';
  }

  @override
  String get queryResultNow => 'Resultado ahora';

  @override
  String queryResultPoints(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count puntos',
      one: '1 punto',
    );
    return '$_temp0';
  }

  @override
  String queryDeleteConfirmTitle(String name) {
    return '¿Eliminar la consulta «$name»?';
  }

  @override
  String queryDeleteConfirmBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count widgets la usan y mostrarán un error hasta que los edites.',
      one: '1 widget la usa y mostrará un error hasta que lo edites.',
    );
    return '$_temp0';
  }

  @override
  String get queryDelete => 'Eliminar consulta';

  @override
  String get queryKeep => 'Conservar consulta';

  @override
  String get devicesNetworkingMissingBody =>
      'Este dispositivo aún no tiene identidad para emparejar.';

  @override
  String get devicesLocalNameHint =>
      'Nombre que ven otros dispositivos al emparejar';

  @override
  String get devicesRenameSubtitle =>
      'Solo cambia el nombre en este dispositivo';

  @override
  String get devicesNameLabel => 'Nombre';

  @override
  String get devicesKeepDevice => 'Conservar dispositivo';

  @override
  String get devicesKeep => 'Conservar';

  @override
  String get devicesSwitchError => 'No se pudo cambiar. Inténtalo de nuevo.';

  @override
  String devicesPausedSynced(String time) {
    return 'En pausa en este dispositivo · última sincronización $time';
  }

  @override
  String get devicesPausedNever =>
      'En pausa en este dispositivo · nunca sincronizado';

  @override
  String get sidebarSyncOff => 'sincronización desactivada';

  @override
  String get sidebarPairingOpen => 'emparejamiento abierto';

  @override
  String get devicesChipPaused =>
      'En pausa · la sincronización con dispositivos emparejados está desactivada';

  @override
  String get devicesChipPausedShort => 'En pausa · sincronización desactivada';

  @override
  String get devicesFactLastEndpoint => 'Último punto de conexión';

  @override
  String devicesUdpPort(int port) {
    return 'UDP $port';
  }

  @override
  String get pairingOpen => 'El emparejamiento está abierto';

  @override
  String pairingTimeLeft(String time) {
    return 'Quedan $time de 2:00 · inícialo también en el otro dispositivo';
  }

  @override
  String pairingNearby(int count) {
    return 'Cerca · $count';
  }

  @override
  String get pairingHiddenPaired =>
      'Los dispositivos que ya emparejaste están ocultos.';

  @override
  String get pairingExpiredTitle => 'El emparejamiento caducó';

  @override
  String get pairingExpiredBody =>
      'El emparejamiento se cerró tras 2 minutos. Inícialo de nuevo en ambos dispositivos cuando estén cerca.';

  @override
  String get pairingRejectedTitle => 'Emparejamiento rechazado';

  @override
  String get pairingRejectedBody =>
      'Se rechazó el código. No se emparejó nada.';

  @override
  String get pairingConfirmTitle => 'Confirmar el código';

  @override
  String get pairingConfirmInstruction =>
      'Comprueba que el otro dispositivo muestra el mismo código y confirma en ambos.';

  @override
  String pairingWith(String name) {
    return 'Emparejando con $name';
  }

  @override
  String pairingPeerIdOf(String name) {
    return 'ID del dispositivo de $name';
  }

  @override
  String get pairingReject => 'Rechazar';

  @override
  String get pairingConfirm => 'Confirmar';

  @override
  String get pairingSavingTrust => 'Guardando la confianza…';

  @override
  String get pairingKeyringLine =>
      'Desbloquea el llavero del escritorio y vuelve a intentarlo.';

  @override
  String get resetParagraph =>
      'Esto borra la única copia del conjunto de datos en este dispositivo. Los demás dispositivos conservan sus copias y no reciben aviso del restablecimiento. Si es el único dispositivo, los datos se pierden para siempre.';

  @override
  String get resetAcknowledge => 'Entiendo que no se puede deshacer';

  @override
  String get resetKeep => 'Conservar datos';

  @override
  String get setupTitle => 'Configura este dispositivo';

  @override
  String get setupLead =>
      'Tus datos se quedan en tus dispositivos. Elige cómo empieza este.';

  @override
  String get setupCreateTitle => 'Crear un conjunto de datos nuevo';

  @override
  String get setupCreateBody =>
      'Empieza de cero. Puedes vincular otros dispositivos después.';

  @override
  String get setupCreateLocked =>
      'No disponible mientras la vinculación está abierta. Detén la vinculación para crear uno.';

  @override
  String get setupJoinTitle => 'Unirse a un conjunto de datos existente';

  @override
  String get setupJoinBody =>
      'Copia el conjunto de datos de otro de tus dispositivos.';

  @override
  String get setupJoinNeedsDataset =>
      'El otro dispositivo ya debe tener un conjunto de datos.';

  @override
  String get setupJoinOneSide =>
      'Inicia la conexión desde solo uno de los dos dispositivos.';

  @override
  String setupPairingStatus(String time) {
    return 'Vinculación abierta · quedan $time';
  }

  @override
  String get setupPairingWaiting =>
      'Esperando a tu otro dispositivo. Toca Conectar en un solo dispositivo.';

  @override
  String get setupStopPairing => 'Detener vinculación';

  @override
  String get joinLead =>
      'Inicia la vinculación también en el otro dispositivo. Toca Conectar en un solo dispositivo.';

  @override
  String get couldntJoinTitle => 'No se pudo unir';

  @override
  String get couldntJoinBody =>
      'El otro dispositivo aún no tiene un conjunto de datos. Crea uno allí primero, o crea uno aquí.';

  @override
  String joiningTitleNamed(String name) {
    return 'Uniéndose a “$name”';
  }

  @override
  String get joiningTitle => 'Uniéndose al otro dispositivo';

  @override
  String joiningBodyNamed(String name) {
    return 'Copiando el conjunto de datos de $name. Mantén ambos dispositivos abiertos hasta que termine.';
  }

  @override
  String get joiningBody =>
      'Copiando el conjunto de datos del otro dispositivo. Mantén ambos dispositivos abiertos hasta que termine.';

  @override
  String get mismatchTitle => 'Este dispositivo tiene otro conjunto de datos';

  @override
  String mismatchBodyNamed(String name) {
    return '“$name” usa otro conjunto de datos que este dispositivo. Los dispositivos solo se sincronizan cuando comparten el mismo.';
  }

  @override
  String get mismatchBody =>
      'El otro dispositivo usa otro conjunto de datos que este dispositivo. Los dispositivos solo se sincronizan cuando comparten el mismo.';

  @override
  String get mismatchResetNote =>
      'Para unirte, primero restablece los datos de este dispositivo. Las colecciones de este dispositivo se eliminarán; el otro dispositivo conserva sus datos.';

  @override
  String get resetDataEllipsis => 'Restablecer los datos de este dispositivo…';

  @override
  String get fatalTitle => 'Fi no pudo iniciar';

  @override
  String get fatalResetBody =>
      'Los datos locales de este dispositivo no se pueden abrir. Reintentar no lo arreglará. Restablecer elimina la copia de este dispositivo; tus otros dispositivos conservan la suya.';

  @override
  String get fatalCopyDetails => 'Copiar detalles';

  @override
  String get fatalDetailsCopied => 'Detalles copiados';

  @override
  String get recoveringTitle => 'Recuperando los datos de este dispositivo';

  @override
  String get recoveringBody =>
      'Fi está recuperando el conjunto de datos de tus otros dispositivos. Mantenlos abiertos.';

  @override
  String get recoveryNeedsDeviceBody =>
      'La copia del conjunto de datos de este dispositivo está dañada. Abre Fi en un dispositivo vinculado de la misma red para restaurarla, o restablece.';

  @override
  String get deferredLockedTitle =>
      'Sincronización desactivada: el llavero del escritorio está bloqueado';

  @override
  String get deferredLockedBody =>
      'Fi guarda las claves de este dispositivo en el llavero del escritorio. Desbloquéalo y reintenta. Tus datos aquí siguen funcionando.';

  @override
  String get deferredNoKeyringTitle =>
      'Sincronización desactivada: no hay llavero disponible';

  @override
  String get deferredNoKeyringBody =>
      'Instala y desbloquea un llavero de escritorio (GNOME Keyring o KWallet) y reintenta.';

  @override
  String deferredPortsTitle(int first, int last) {
    return 'Sincronización desactivada: UDP $first–$last están en uso';
  }

  @override
  String get deferredPortsBody =>
      'Otro programa u otra copia de Fi está usando estos puertos. Tus datos aquí siguen funcionando.';

  @override
  String get sidebarCauseLocked => 'llavero bloqueado';

  @override
  String get sidebarCauseNoKeyring => 'sin llavero';

  @override
  String get sidebarCausePorts => 'puertos en uso';
}
