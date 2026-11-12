import 'dart:typed_data';

import '../features/company/company_model.dart';
import 'api_client.dart';
import 'india_states.dart';
import 'pdf_kit.dart';

/// Downloads the company logo (`GET /files/:id`). Any user of the company
/// can read it; returns null when there is no logo or it can't be fetched.
Future<Uint8List?> fetchCompanyLogo(ApiClient api, Company company) async {
  final id = company.logoFileId;
  if (id == null || id.isEmpty) return null;
  try {
    return await api.getBytes('/files/$id');
  } catch (_) {
    return null;
  }
}

/// The PDF identity for [company]; pass [logo] bytes from [fetchCompanyLogo].
PdfBrand pdfBrandFor(Company company, {Uint8List? logo}) {
  bool has(String? v) => v != null && v.trim().isNotEmpty;
  final state = stateName(company.stateCode);
  return PdfBrand(
    companyName: company.name,
    legalName: company.legalName,
    colorHex: company.brandColor,
    logoBytes: logo,
    addressLines: [
      if (has(company.address)) company.address!,
      if (has(company.pincode)) 'PIN ${company.pincode}',
    ],
    idLine: [
      if (has(company.gstin)) 'GSTIN: ${company.gstin}',
      if (has(company.pan)) 'PAN: ${company.pan}',
      if (state != null) 'State: $state (${company.stateCode})',
    ].join('   '),
    contactLine: [
      if (has(company.phone)) 'Phone: ${company.phone}',
      if (has(company.email)) company.email!,
      if (has(company.website)) company.website!,
    ].join('   '),
  );
}

/// Convenience used by screens: fetch the logo, then build the brand.
Future<PdfBrand> loadPdfBrand(ApiClient api, Company company) async =>
    pdfBrandFor(company, logo: await fetchCompanyLogo(api, company));
