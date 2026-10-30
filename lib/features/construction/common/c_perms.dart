/// Permission keys of the construction pack (API v1.2).
///
/// Kept here rather than in `core/permissions.dart` so the pack can be wired
/// in without touching shared files.
abstract final class CPerm {
  static const projectsView = 'projects.view';
  static const projectsManage = 'projects.manage';
  static const boqManage = 'boq.manage';
  static const indentsView = 'indents.view';
  static const indentsCreate = 'indents.create';
  static const indentsApprove = 'indents.approve';
  static const consumptionView = 'consumption.view';
  static const consumptionCreate = 'consumption.create';
  static const dprView = 'dpr.view';
  static const dprCreate = 'dpr.create';
  static const dprApprove = 'dpr.approve';
  static const labourView = 'labour.view';
  static const labourManage = 'labour.manage';
  static const attendanceMark = 'attendance.mark';
  static const wagesView = 'wages.view';
  static const wagesManage = 'wages.manage';
  static const wagesPay = 'wages.pay';
  static const subcontractsView = 'subcontracts.view';
  static const subcontractsManage = 'subcontracts.manage';
  static const subcontractsApprove = 'subcontracts.approve';

  /// Every key above.
  static const all = [
    projectsView,
    projectsManage,
    boqManage,
    indentsView,
    indentsCreate,
    indentsApprove,
    consumptionView,
    consumptionCreate,
    dprView,
    dprCreate,
    dprApprove,
    labourView,
    labourManage,
    attendanceMark,
    wagesView,
    wagesManage,
    wagesPay,
    subcontractsView,
    subcontractsManage,
    subcontractsApprove,
  ];
}
