import '../services/supabase_service.dart';

class DistributionPartnerRecord {
  const DistributionPartnerRecord({
    required this.id,
    required this.partnerId,
    required this.companyName,
    required this.contactFirstName,
    required this.contactLastName,
    required this.email,
    required this.phone,
    required this.addressLine1,
    required this.addressLine2,
    required this.city,
    required this.state,
    required this.postalCode,
    required this.country,
    required this.username,
    required this.isActive,
  });

  final String id;
  final String partnerId;
  final String companyName;
  final String contactFirstName;
  final String contactLastName;
  final String email;
  final String phone;
  final String addressLine1;
  final String addressLine2;
  final String city;
  final String state;
  final String postalCode;
  final String country;
  final String username;
  final bool isActive;

  String get displayLabel => '$partnerId - $companyName';

  factory DistributionPartnerRecord.fromMap(Map<String, dynamic> row) {
    return DistributionPartnerRecord(
      id: (row['id'] ?? '').toString(),
      partnerId: (row['partner_id'] ?? '').toString(),
      companyName: (row['company_name'] ?? '').toString(),
      contactFirstName: (row['contact_first_name'] ?? '').toString(),
      contactLastName: (row['contact_last_name'] ?? '').toString(),
      email: (row['email'] ?? '').toString(),
      phone: (row['phone'] ?? '').toString(),
      addressLine1: (row['address_line_1'] ?? '').toString(),
      addressLine2: (row['address_line_2'] ?? '').toString(),
      city: (row['city'] ?? '').toString(),
      state: (row['state'] ?? '').toString(),
      postalCode: (row['postal_code'] ?? '').toString(),
      country: (row['country'] ?? '').toString(),
      username: (row['username'] ?? '').toString(),
      isActive: row['is_active'] == true,
    );
  }
}

class OrganizationRecord {
  const OrganizationRecord({
    required this.id,
    required this.organizationNumber,
    required this.name,
    required this.licenseKey,
    required this.isActive,
    required this.contactName,
    required this.contactEmail,
    required this.contactPhone,
    required this.partnerId,
    required this.partnerCompanyName,
  });

  final String id;
  final String organizationNumber;
  final String name;
  final String licenseKey;
  final bool isActive;
  final String contactName;
  final String contactEmail;
  final String contactPhone;
  final String partnerId;
  final String partnerCompanyName;

  factory OrganizationRecord.fromMap(Map<String, dynamic> row) {
    return OrganizationRecord(
      id: (row['id'] ?? '').toString(),
      organizationNumber: (row['organization_number'] ?? '').toString(),
      name: (row['name'] ?? '').toString(),
      licenseKey: (row['license_key'] ?? '').toString(),
      isActive: row['is_active'] == true,
      contactName: (row['contact_name'] ?? '').toString(),
      contactEmail: (row['contact_email'] ?? '').toString(),
      contactPhone: (row['contact_phone'] ?? '').toString(),
      partnerId: (row['partner_id'] ?? '').toString(),
      partnerCompanyName: (row['partner_company_name'] ?? '').toString(),
    );
  }
}

class LocationRecord {
  const LocationRecord({
    required this.id,
    required this.organizationId,
    required this.organizationNumber,
    required this.organizationLicenseKey,
    required this.name,
    required this.email,
    required this.phone,
    required this.address,
    required this.address2,
    required this.city,
    required this.state,
    required this.zip,
    required this.terminalLicenses,
    required this.terminalsActive,
    required this.receiptCardSignatureMessage,
  });

  final String id;
  final String organizationId;
  final String organizationNumber;
  final String organizationLicenseKey;
  final String name;
  final String email;
  final String phone;
  final String address;
  final String address2;
  final String city;
  final String state;
  final String zip;
  final int terminalLicenses;
  final int terminalsActive;
  final String receiptCardSignatureMessage;

  factory LocationRecord.fromMap(Map<String, dynamic> row) {
    int parseInt(dynamic value, int fallback) {
      if (value is int) return value;
      return int.tryParse((value ?? '').toString()) ?? fallback;
    }

    return LocationRecord(
      id: (row['id'] ?? '').toString(),
      organizationId: (row['organization_id'] ?? '').toString(),
      organizationNumber: (row['organization_number'] ?? '').toString(),
      organizationLicenseKey: (row['organization_license_key'] ?? '').toString(),
      name: (row['name'] ?? '').toString(),
      email: (row['email'] ?? '').toString(),
      phone: (row['phone'] ?? '').toString(),
      address: (row['address'] ?? '').toString(),
      address2: (row['address_2'] ?? '').toString(),
      city: (row['city'] ?? '').toString(),
      state: (row['state'] ?? '').toString(),
      zip: (row['zip'] ?? '').toString(),
      terminalLicenses: parseInt(row['terminal_licenses'], 1),
      terminalsActive: parseInt(row['terminals_active'], 0),
      receiptCardSignatureMessage:
          (row['receipt_card_signature_message'] ?? '').toString(),
    );
  }
}

class OrganizationAdminService {
  Future<List<DistributionPartnerRecord>> listDistributionPartners() async {
    final dynamic response = await SupabaseService.client.rpc(
      'list_distribution_partners_console_from_app',
    );

    if (response is! List) {
      return const [];
    }

    return response
        .whereType<Map>()
        .map(
          (row) =>
              DistributionPartnerRecord.fromMap(Map<String, dynamic>.from(row)),
        )
        .toList();
  }

  Future<DistributionPartnerRecord> createDistributionPartner({
    required String companyName,
    required String contactFirstName,
    required String contactLastName,
    required String email,
    required String phone,
    required String addressLine1,
    required String addressLine2,
    required String city,
    required String state,
    required String postalCode,
    required String country,
  }) async {
    final dynamic response = await SupabaseService.client.rpc(
      'create_distribution_partner_console_from_app',
      params: {
        'p_company_name': companyName.trim(),
        'p_contact_first_name': contactFirstName.trim(),
        'p_contact_last_name': contactLastName.trim(),
        'p_email': email.trim(),
        'p_phone': phone.trim(),
        'p_address_line_1': addressLine1.trim(),
        'p_address_line_2': addressLine2.trim(),
        'p_city': city.trim(),
        'p_state': state.trim(),
        'p_postal_code': postalCode.trim(),
        'p_country': country.trim(),
      },
    );

    if (response is! List || response.isEmpty) {
      throw Exception('No partner row returned from create operation.');
    }

    final row = Map<String, dynamic>.from(response.first as Map);
    return DistributionPartnerRecord.fromMap(row);
  }

  Future<DistributionPartnerRecord> updateDistributionPartner({
    required String id,
    required String companyName,
    required String contactFirstName,
    required String contactLastName,
    required String email,
    required String phone,
    required String addressLine1,
    required String addressLine2,
    required String city,
    required String state,
    required String postalCode,
    required String country,
  }) async {
    final dynamic response = await SupabaseService.client.rpc(
      'update_distribution_partner_console_from_app',
      params: {
        'p_id': id.trim(),
        'p_company_name': companyName.trim(),
        'p_contact_first_name': contactFirstName.trim(),
        'p_contact_last_name': contactLastName.trim(),
        'p_email': email.trim(),
        'p_phone': phone.trim(),
        'p_address_line_1': addressLine1.trim(),
        'p_address_line_2': addressLine2.trim(),
        'p_city': city.trim(),
        'p_state': state.trim(),
        'p_postal_code': postalCode.trim(),
        'p_country': country.trim(),
      },
    );

    if (response is! List || response.isEmpty) {
      throw Exception('No partner row returned from update operation.');
    }

    final row = Map<String, dynamic>.from(response.first as Map);
    return DistributionPartnerRecord.fromMap(row);
  }

  Future<List<OrganizationRecord>> listOrganizations() async {
    final dynamic response = await SupabaseService.client.rpc(
      'list_organizations_console_from_app',
    );

    if (response is! List) {
      return const [];
    }

    return response
        .whereType<Map>()
        .map(
          (row) => OrganizationRecord.fromMap(Map<String, dynamic>.from(row)),
        )
        .toList();
  }

  Future<OrganizationRecord> upsertOrganization({
    String? id,
    required String organizationNumber,
    required String name,
    required String licenseKey,
    required String contactName,
    required String contactEmail,
    required String contactPhone,
    required String partnerId,
  }) async {
    final dynamic response = await SupabaseService.client.rpc(
      'upsert_organization_console_from_app',
      params: {
        'p_id': (id ?? '').trim().isEmpty ? null : id!.trim(),
        'p_organization_number': organizationNumber.trim(),
        'p_name': name.trim(),
        'p_license_key': licenseKey.trim(),
        'p_contact_name': contactName.trim(),
        'p_contact_email': contactEmail.trim(),
        'p_contact_phone': contactPhone.trim(),
        'p_partner_id': partnerId.trim(),
      },
    );

    if (response is! List || response.isEmpty) {
      throw Exception('No organization row returned from save operation.');
    }

    final row = Map<String, dynamic>.from(response.first as Map);
    return OrganizationRecord.fromMap(row);
  }

  Future<List<LocationRecord>> listLocations({
    required String organizationId,
  }) async {
    final dynamic response = await SupabaseService.client.rpc(
      'list_locations_console_from_app',
      params: {
        'p_organization_id': organizationId,
      },
    );

    if (response is! List) {
      return const [];
    }

    return response
        .whereType<Map>()
        .map(
          (row) => LocationRecord.fromMap(Map<String, dynamic>.from(row)),
        )
        .toList();
  }

  Future<LocationRecord> upsertLocation({
    String? id,
    required String organizationId,
    required String name,
    required String email,
    required String phone,
    required String address,
    required String address2,
    required String city,
    required String state,
    required String zip,
    required int terminalLicenses,
  }) async {
    final dynamic response = await SupabaseService.client.rpc(
      'upsert_location_console_from_app',
      params: {
        'p_id': (id ?? '').trim().isEmpty ? null : id!.trim(),
        'p_organization_id': organizationId.trim(),
        'p_name': name.trim(),
        'p_email': email.trim(),
        'p_phone': phone.trim(),
        'p_address': address.trim(),
        'p_address_2': address2.trim(),
        'p_city': city.trim(),
        'p_state': state.trim(),
        'p_zip': zip.trim(),
        'p_terminal_licenses': terminalLicenses,
      },
    );

    if (response is! List || response.isEmpty) {
      throw Exception('No location row returned from save operation.');
    }

    final row = Map<String, dynamic>.from(response.first as Map);
    return LocationRecord.fromMap(row);
  }
}
