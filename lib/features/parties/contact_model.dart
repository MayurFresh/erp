import '../../core/json.dart';

/// A contact person of a customer or vendor.
class ContactPerson {
  const ContactPerson({
    required this.id,
    required this.name,
    this.designation,
    this.phone,
    this.email,
    this.isPrimary = false,
    this.notes,
  });

  factory ContactPerson.fromJson(Json j) => ContactPerson(
    id: asString(j['id']),
    name: asString(j['name']),
    designation: asStringOrNull(j['designation']),
    phone: asStringOrNull(j['phone']),
    email: asStringOrNull(j['email']),
    isPrimary: asBool(j['isPrimary']),
    notes: asStringOrNull(j['notes']),
  );

  final String id;
  final String name;
  final String? designation;
  final String? phone;
  final String? email;
  final bool isPrimary;
  final String? notes;
}
