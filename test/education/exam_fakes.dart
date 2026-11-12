import 'package:dio/dio.dart';

Map<String, Object?> _term({bool published = false}) => {
  'id': 't1',
  'yearId': 'y1',
  'name': 'Unit test 1',
  'seq': 1,
  'status': published ? 'published' : 'draft',
  'published': published,
  'updatedAt': '2026-07-01T00:00:00.000Z',
  'papers': 2,
};

const _papers = [
  {
    'id': 'pm',
    'subjectId': 'sm',
    'subject': 'Mathematics',
    'maxMarks': 50,
    'passMarks': 17,
  },
  {
    'id': 'pe',
    'subjectId': 'se',
    'subject': 'English',
    'maxMarks': 50,
    'passMarks': null,
  },
];

Map<String, Object?> examGrid({bool locked = false}) => {
  'term': _term(published: locked),
  'classId': 'c1',
  'label': 'Class 5 A',
  'locked': locked,
  'papers': _papers,
  'students': [
    {
      'studentId': 'a',
      'name': 'Asha Shah',
      'rollNo': '1',
      'marks': {
        'pm': {'marks': 48, 'absent': false},
        'pe': null,
      },
    },
    {
      'studentId': 'b',
      'name': 'Bhavin Mehta',
      'rollNo': '2',
      'marks': {
        'pm': null,
        'pe': {'marks': null, 'absent': true},
      },
    },
  ],
};

Map<String, Object?> examCard() => {
  'school': {
    'name': 'Green Valley School',
    'address': 'Ashram Road',
    'phone': '0791234567',
  },
  'term': {'id': 't1', 'name': 'Unit test 1'},
  'year': '2026-27',
  'classLabel': 'Class 5 A',
  'classSize': 2,
  'draft': false,
  'student': {
    'id': 'a',
    'name': 'Asha Shah',
    'rollNo': '1',
    'admissionNo': 'ADM/26-27/00001',
    'dob': '2015-06-01',
    'guardianName': 'Hetal Shah',
  },
  'subjects': [
    {
      'paperId': 'pm',
      'subject': 'Mathematics',
      'maxMarks': 50,
      'marks': 48,
      'absent': false,
      'grade': 'A1',
      'passed': true,
    },
    {
      'paperId': 'pe',
      'subject': 'English',
      'maxMarks': 50,
      'marks': null,
      'absent': true,
      'grade': null,
      'passed': false,
    },
  ],
  'total': 48,
  'maxTotal': 100,
  'percentage': 48,
  'grade': 'C2',
  'rank': 1,
  'result': 'fail',
  'complete': true,
  'remark': 'Bright and regular.',
  'coScholastic': [
    {'area': 'Discipline', 'grade': 'A'},
    {'area': 'Art education', 'grade': null},
  ],
  'attendance': {'marked': 20, 'present': 18},
  'grades': [
    {'grade': 'A1', 'minPct': 91},
    {'grade': 'E', 'minPct': 0},
  ],
};

(int, Object?)? examRoute(RequestOptions o) {
  final key = '${o.method} ${o.path}';
  return switch (key) {
    'GET /education/exam-terms' => (
      200,
      {
        'data': [
          {..._term(), 'classes': 1},
        ],
      },
    ),
    'GET /education/exam-terms/t1' => (
      200,
      {
        ..._term(),
        'classes': [
          {
            'id': 'c1',
            'label': 'Class 5 A',
            'students': 2,
            'papers': 2,
            'entered': 2,
            'expected': 4,
            'mine': true,
          },
        ],
      },
    ),
    'GET /education/exam-settings' => (
      200,
      {
        'grades': [
          {'grade': 'A1', 'minPct': 91},
          {'grade': 'E', 'minPct': 0},
        ],
        'coGrades': [
          {'grade': 'A', 'label': 'Very good'},
          {'grade': 'B', 'label': 'Good'},
        ],
        'passPercent': 33,
        'isDefault': true,
      },
    ),
    'GET /education/exam-terms/t1/classes/c1/marks' => (200, examGrid()),
    'POST /education/exam-terms/t1/classes/c1/marks' => (200, examGrid()),
    'POST /education/exam-terms/t1/publish' => (200, _term(published: true)),
    'GET /education/exam-terms/t1/classes/c1/results' => (
      200,
      {
        'label': 'Class 5 A',
        'locked': false,
        'ranked': 1,
        'students': [
          {...examCard(), 'studentId': 'a', 'name': 'Asha Shah'},
        ],
      },
    ),
    'GET /education/exam-terms/t1/classes/c1/report-cards' => (
      200,
      {
        'data': [examCard()],
      },
    ),
    'GET /education/exam-terms/t1/classes/c1/remarks' => (
      200,
      {
        'label': 'Class 5 A',
        'locked': false,
        'areas': ['Discipline', 'Art education'],
        'coGrades': [
          {'grade': 'A', 'label': 'Very good'},
          {'grade': 'B', 'label': 'Good'},
          {'grade': 'C', 'label': 'Needs work'},
        ],
        'students': [
          {
            'studentId': 'a',
            'name': 'Asha Shah',
            'rollNo': '1',
            'remark': 'Bright.',
            'coScholastic': [
              {'area': 'Discipline', 'grade': 'A'},
              {'area': 'Art education', 'grade': null},
            ],
          },
          {
            'studentId': 'b',
            'name': 'Bhavin Mehta',
            'rollNo': '2',
            'remark': null,
            'coScholastic': [
              {'area': 'Discipline', 'grade': null},
              {'area': 'Art education', 'grade': null},
            ],
          },
        ],
      },
    ),
    'POST /education/exam-terms/t1/classes/c1/remarks' => (
      200,
      <String, Object?>{},
    ),
    'GET /education/classes/c1/co-areas' => (
      200,
      {
        'areas': ['Discipline', 'Art education'],
        'isDefault': false,
      },
    ),
    'POST /education/classes/c1/co-areas' => (
      200,
      {'areas': <String>[], 'isDefault': false},
    ),
    'PATCH /education/exam-settings' => (
      200,
      {'coGrades': <Object>[], 'grades': <Object>[]},
    ),
    'GET /education/subjects' => (200, {'data': <Object>[]}),
    _ => null,
  };
}
