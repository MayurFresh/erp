import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';

String fmtMarks(num? v) {
  if (v == null) return '';
  return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
}

class GradeBand {
  const GradeBand(this.grade, this.minPct);
  factory GradeBand.fromJson(Json j) =>
      GradeBand(asString(j['grade']), asDouble(j['minPct']));
  final String grade;
  final double minPct;
}

class ExamSettings {
  const ExamSettings({
    this.coGrades = const [],
    required this.grades,
    required this.passPercent,
    required this.isDefault,
  });
  factory ExamSettings.fromJson(Json j) => ExamSettings(
    coGrades: [
      for (final g in asJsonList(j['coGrades']))
        CoScale(asString(g['grade']), asString(g['label'])),
    ],
    grades: [for (final g in asJsonList(j['grades'])) GradeBand.fromJson(g)],
    passPercent: asDouble(j['passPercent'], 33),
    isDefault: asBool(j['isDefault']),
  );
  final List<CoScale> coGrades;
  final List<GradeBand> grades;
  final double passPercent;
  final bool isDefault;
}

class Subject {
  const Subject({
    required this.id,
    required this.classId,
    required this.name,
    this.isActive = true,
  });
  factory Subject.fromJson(Json j) => Subject(
    id: asString(j['id']),
    classId: asString(j['classId']),
    name: asString(j['name']),
    isActive: asBool(j['isActive'], true),
  );
  final String id;
  final String classId;
  final String name;
  final bool isActive;
}

class ExamTerm {
  const ExamTerm({
    required this.id,
    required this.yearId,
    required this.name,
    required this.published,
    this.papers = 0,
    this.classes = const [],
    this.classCount = 0,
    this.updatedAt,
  });
  factory ExamTerm.fromJson(Json j) => ExamTerm(
    id: asString(j['id']),
    yearId: asString(j['yearId']),
    name: asString(j['name']),
    published: asBool(j['published']),
    papers: asInt(j['papers']),
    classCount: j['classes'] is num ? asInt(j['classes']) : 0,
    classes: j['classes'] is List
        ? [for (final c in asJsonList(j['classes'])) TermClass.fromJson(c)]
        : const [],
    updatedAt: j['updatedAt']?.toString(),
  );
  final String id;
  final String yearId;
  final String name;
  final bool published;
  final int papers;
  final int classCount;
  final List<TermClass> classes;
  final String? updatedAt;
}

class TermClass {
  const TermClass({
    required this.id,
    required this.label,
    required this.students,
    required this.papers,
    required this.entered,
    required this.expected,
  });
  factory TermClass.fromJson(Json j) => TermClass(
    id: asString(j['id']),
    label: asString(j['label']),
    students: asInt(j['students']),
    papers: asInt(j['papers']),
    entered: asInt(j['entered']),
    expected: asInt(j['expected']),
  );
  final String id;
  final String label;
  final int students;
  final int papers;
  final int entered;
  final int expected;
}

class Paper {
  const Paper({
    required this.id,
    required this.subjectId,
    required this.subject,
    required this.maxMarks,
    this.passMarks,
  });
  factory Paper.fromJson(Json j) => Paper(
    id: asString(j['id']),
    subjectId: asString(j['subjectId']),
    subject: asString(j['subject']),
    maxMarks: asDouble(j['maxMarks']),
    passMarks: asDoubleOrNull(j['passMarks']),
  );
  final String id;
  final String subjectId;
  final String subject;
  final double maxMarks;
  final double? passMarks;
}

/// One mark cell. [absent] and [marks] are never both set.
class Cell {
  const Cell({this.marks, this.absent = false});
  final double? marks;
  final bool absent;
  bool get empty => marks == null && !absent;
}

class MarkRow {
  MarkRow({
    required this.studentId,
    required this.name,
    this.rollNo,
    required this.cells,
  });
  final String studentId;
  final String name;
  final String? rollNo;
  final Map<String, Cell> cells;
}

class MarkGrid {
  const MarkGrid({
    required this.label,
    required this.locked,
    required this.papers,
    required this.students,
  });
  factory MarkGrid.fromJson(Json j) {
    final papers = [for (final p in asJsonList(j['papers'])) Paper.fromJson(p)];
    return MarkGrid(
      label: asString(j['label']),
      locked: asBool(j['locked']),
      papers: papers,
      students: [
        for (final s in asJsonList(j['students']))
          MarkRow(
            studentId: asString(s['studentId']),
            name: asString(s['name']),
            rollNo: asStringOrNull(s['rollNo']),
            cells: {
              for (final p in papers)
                p.id: s['marks'] is Map && (s['marks'] as Map)[p.id] is Map
                    ? Cell(
                        marks: asDoubleOrNull(
                          (s['marks'] as Map)[p.id]['marks'],
                        ),
                        absent: asBool((s['marks'] as Map)[p.id]['absent']),
                      )
                    : const Cell(),
            },
          ),
      ],
    );
  }
  final String label;
  final bool locked;
  final List<Paper> papers;
  final List<MarkRow> students;
}

class SubjectResult {
  const SubjectResult({
    required this.subject,
    required this.maxMarks,
    this.marks,
    this.absent = false,
    this.grade,
    this.passed,
  });
  factory SubjectResult.fromJson(Json j) => SubjectResult(
    subject: asString(j['subject']),
    maxMarks: asDouble(j['maxMarks']),
    marks: asDoubleOrNull(j['marks']),
    absent: asBool(j['absent']),
    grade: asStringOrNull(j['grade']),
    passed: j['passed'] == null ? null : asBool(j['passed']),
  );
  final String subject;
  final double maxMarks;
  final double? marks;
  final bool absent;
  final String? grade;
  final bool? passed;
}

class CoGrade {
  const CoGrade(this.area, this.grade);
  final String area;
  final String? grade;
}

class CoScale {
  const CoScale(this.grade, this.label);
  final String grade;
  final String label;
}

class RemarkRow {
  RemarkRow({
    required this.studentId,
    required this.name,
    this.rollNo,
    this.remark,
    required this.grades,
  });
  final String studentId;
  final String name;
  final String? rollNo;
  final String? remark;
  final Map<String, String?> grades;
}

class RemarkSheet {
  const RemarkSheet({
    required this.label,
    required this.locked,
    required this.areas,
    required this.scale,
    required this.students,
  });
  factory RemarkSheet.fromJson(Json j) => RemarkSheet(
    label: asString(j['label']),
    locked: asBool(j['locked']),
    areas: [for (final a in (j['areas'] as List? ?? [])) a.toString()],
    scale: [
      for (final g in asJsonList(j['coGrades']))
        CoScale(asString(g['grade']), asString(g['label'])),
    ],
    students: [
      for (final s in asJsonList(j['students']))
        RemarkRow(
          studentId: asString(s['studentId']),
          name: asString(s['name']),
          rollNo: asStringOrNull(s['rollNo']),
          remark: asStringOrNull(s['remark']),
          grades: {
            for (final c in asJsonList(s['coScholastic']))
              asString(c['area']): asStringOrNull(c['grade']),
          },
        ),
    ],
  );
  final String label;
  final bool locked;
  final List<String> areas;
  final List<CoScale> scale;
  final List<RemarkRow> students;
}

class StudentResult {
  const StudentResult({
    this.remark,
    this.coScholastic = const [],
    required this.studentId,
    required this.name,
    this.rollNo,
    required this.subjects,
    required this.total,
    required this.maxTotal,
    this.percentage,
    this.grade,
    this.rank,
    this.result,
    this.complete = false,
  });
  factory StudentResult.fromJson(Json j) => StudentResult(
    studentId: asString(j['studentId'] ?? asJson(j['student'])['id']),
    name: asString(j['name'] ?? asJson(j['student'])['name']),
    rollNo: asStringOrNull(j['rollNo'] ?? asJson(j['student'])['rollNo']),
    subjects: [
      for (final s in asJsonList(j['subjects'])) SubjectResult.fromJson(s),
    ],
    total: asDouble(j['total']),
    maxTotal: asDouble(j['maxTotal']),
    percentage: asDoubleOrNull(j['percentage']),
    grade: asStringOrNull(j['grade']),
    rank: j['rank'] == null ? null : asInt(j['rank']),
    result: asStringOrNull(j['result']),
    complete: asBool(j['complete']),
    remark: asStringOrNull(j['remark']),
    coScholastic: [
      for (final c in asJsonList(j['coScholastic']))
        CoGrade(asString(c['area']), asStringOrNull(c['grade'])),
    ],
  );
  final String? remark;
  final List<CoGrade> coScholastic;
  final String studentId;
  final String name;
  final String? rollNo;
  final List<SubjectResult> subjects;
  final double total;
  final double maxTotal;
  final double? percentage;
  final String? grade;
  final int? rank;
  final String? result;
  final bool complete;
}

class ClassResults {
  const ClassResults({
    required this.label,
    required this.locked,
    required this.ranked,
    required this.students,
  });
  factory ClassResults.fromJson(Json j) => ClassResults(
    label: asString(j['label']),
    locked: asBool(j['locked']),
    ranked: asInt(j['ranked']),
    students: [
      for (final s in asJsonList(j['students'])) StudentResult.fromJson(s),
    ],
  );
  final String label;
  final bool locked;
  final int ranked;
  final List<StudentResult> students;
}

class ReportCard {
  const ReportCard({
    required this.schoolName,
    this.schoolAddress,
    this.schoolPhone,
    required this.termName,
    required this.year,
    required this.classLabel,
    required this.classSize,
    required this.draft,
    required this.result,
    required this.admissionNo,
    this.dob,
    this.guardianName,
    required this.attMarked,
    required this.attPresent,
    required this.grades,
  });
  factory ReportCard.fromJson(Json j) {
    final school = asJson(j['school']);
    final st = asJson(j['student']);
    final att = asJson(j['attendance']);
    return ReportCard(
      schoolName: asString(school['name']),
      schoolAddress: asStringOrNull(school['address']),
      schoolPhone: asStringOrNull(school['phone']),
      termName: asString(asJson(j['term'])['name']),
      year: asString(j['year']),
      classLabel: asString(j['classLabel']),
      classSize: asInt(j['classSize']),
      draft: asBool(j['draft']),
      admissionNo: asString(st['admissionNo']),
      dob: asStringOrNull(st['dob']),
      guardianName: asStringOrNull(st['guardianName']),
      attMarked: asInt(att['marked']),
      attPresent: asInt(att['present']),
      grades: [for (final g in asJsonList(j['grades'])) GradeBand.fromJson(g)],
      result: StudentResult.fromJson(j),
    );
  }
  final String schoolName;
  final String? schoolAddress;
  final String? schoolPhone;
  final String termName;
  final String year;
  final String classLabel;
  final int classSize;
  final bool draft;
  final String admissionNo;
  final String? dob;
  final String? guardianName;
  final int attMarked;
  final int attPresent;
  final List<GradeBand> grades;
  final StudentResult result;
}

enum ExamKind { setup, marks }

final examRevisionProvider =
    NotifierProvider.family<ExamRevision, int, ExamKind>(ExamRevision.new);

class ExamRevision extends Notifier<int> {
  ExamRevision(this.kind);
  final ExamKind kind;
  @override
  int build() => 0;
  void bump() => state++;
}

final examRepositoryProvider = Provider<ExamRepository>(
  (ref) => ExamRepository(ref.watch(apiClientProvider)),
);

final examSettingsProvider = FutureProvider.autoDispose<ExamSettings>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(examRevisionProvider(ExamKind.setup));
  return ref.watch(examRepositoryProvider).settings();
});

final examCoAreasProvider = FutureProvider.autoDispose
    .family<List<String>, String>((ref, classId) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(examRevisionProvider(ExamKind.setup));
      return ref.watch(examRepositoryProvider).coAreas(classId);
    });

final examTermsProvider = FutureProvider.autoDispose<List<ExamTerm>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(examRevisionProvider(ExamKind.setup));
  ref.watch(examRevisionProvider(ExamKind.marks));
  return ref.watch(examRepositoryProvider).terms();
});

final examTermProvider = FutureProvider.autoDispose.family<ExamTerm, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(examRevisionProvider(ExamKind.setup));
  ref.watch(examRevisionProvider(ExamKind.marks));
  return ref.watch(examRepositoryProvider).term(id);
});

final examSubjectsProvider = FutureProvider.autoDispose
    .family<List<Subject>, String>((ref, classId) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(examRevisionProvider(ExamKind.setup));
      return ref.watch(examRepositoryProvider).subjects(classId);
    });

final examPapersProvider = FutureProvider.autoDispose
    .family<List<Paper>, ({String termId, String classId})>((ref, k) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(examRevisionProvider(ExamKind.setup));
      return ref.watch(examRepositoryProvider).papers(k.termId, k.classId);
    });

final examGridProvider = FutureProvider.autoDispose
    .family<MarkGrid, ({String termId, String classId})>((ref, k) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(examRevisionProvider(ExamKind.setup));
      return ref.watch(examRepositoryProvider).grid(k.termId, k.classId);
    });

final examRemarksProvider = FutureProvider.autoDispose
    .family<RemarkSheet, ({String termId, String classId})>((ref, k) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(examRevisionProvider(ExamKind.setup));
      return ref.watch(examRepositoryProvider).remarks(k.termId, k.classId);
    });

final examResultsProvider = FutureProvider.autoDispose
    .family<ClassResults, ({String termId, String classId})>((ref, k) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(examRevisionProvider(ExamKind.setup));
      ref.watch(examRevisionProvider(ExamKind.marks));
      return ref.watch(examRepositoryProvider).results(k.termId, k.classId);
    });

class ExamRepository {
  ExamRepository(this._api);
  final ApiClient _api;

  Future<ExamSettings> settings() async =>
      ExamSettings.fromJson(await _api.getJson('/education/exam-settings'));

  Future<ExamSettings> saveSettings(Json body) async => ExamSettings.fromJson(
    await _api.patchJson('/education/exam-settings', body: body),
  );

  Future<List<String>> coAreas(String classId) async => [
    for (final a
        in (await _api.getJson('/education/classes/$classId/co-areas'))['areas']
            as List)
      a.toString(),
  ];

  Future<void> saveCoAreas(String classId, List<String> areas) => _api.postJson(
    '/education/classes/$classId/co-areas',
    body: {'areas': areas},
  );

  Future<List<ExamTerm>> terms() async => [
    for (final j in asJsonList(
      (await _api.getJson('/education/exam-terms'))['data'],
    ))
      ExamTerm.fromJson(j),
  ];

  Future<ExamTerm> term(String id) async =>
      ExamTerm.fromJson(await _api.getJson('/education/exam-terms/$id'));

  Future<ExamTerm> saveTerm(String? id, Json body) async => ExamTerm.fromJson(
    id == null
        ? await _api.postJson('/education/exam-terms', body: body)
        : await _api.patchJson('/education/exam-terms/$id', body: body),
  );

  Future<ExamTerm> publish(String id) async => ExamTerm.fromJson(
    await _api.postJson('/education/exam-terms/$id/publish'),
  );

  Future<ExamTerm> reopen(String id) async => ExamTerm.fromJson(
    await _api.postJson('/education/exam-terms/$id/reopen'),
  );

  Future<List<Subject>> subjects(String classId) async => [
    for (final j in asJsonList(
      (await _api.getJson(
        '/education/subjects',
        query: {'classId': classId},
      ))['data'],
    ))
      Subject.fromJson(j),
  ];

  Future<void> saveSubject(String? id, Json body) async {
    if (id == null) {
      await _api.postJson('/education/subjects', body: body);
    } else {
      await _api.patchJson('/education/subjects/$id', body: body);
    }
  }

  Future<List<Paper>> papers(String termId, String classId) async => [
    for (final j in asJsonList(
      (await _api.getJson(
        '/education/exam-terms/$termId/papers',
        query: {'classId': classId},
      ))['data'],
    ))
      Paper.fromJson(j),
  ];

  /// The server accepts POST as well as PUT for this write.
  Future<void> savePapers(String termId, String classId, List<Json> papers) =>
      _api.postJson(
        '/education/exam-terms/$termId/papers',
        body: {'classId': classId, 'papers': papers},
      );

  Future<MarkGrid> grid(String termId, String classId) async =>
      MarkGrid.fromJson(
        await _api.getJson(
          '/education/exam-terms/$termId/classes/$classId/marks',
        ),
      );

  Future<void> saveMarks(String termId, String classId, List<Json> entries) =>
      _api.postJson(
        '/education/exam-terms/$termId/classes/$classId/marks',
        body: {'entries': entries},
      );

  Future<RemarkSheet> remarks(String termId, String classId) async =>
      RemarkSheet.fromJson(
        await _api.getJson(
          '/education/exam-terms/$termId/classes/$classId/remarks',
        ),
      );

  Future<void> saveRemarks(String termId, String classId, List<Json> entries) =>
      _api.postJson(
        '/education/exam-terms/$termId/classes/$classId/remarks',
        body: {'entries': entries},
      );

  Future<ClassResults> results(String termId, String classId) async =>
      ClassResults.fromJson(
        await _api.getJson(
          '/education/exam-terms/$termId/classes/$classId/results',
        ),
      );

  Future<List<ReportCard>> cards(String termId, String classId) async => [
    for (final j in asJsonList(
      (await _api.getJson(
        '/education/exam-terms/$termId/classes/$classId/report-cards',
      ))['data'],
    ))
      ReportCard.fromJson(j),
  ];
}
