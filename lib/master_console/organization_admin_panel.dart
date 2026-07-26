import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'organization_admin_service.dart';

class OrganizationAdminPanel extends StatefulWidget {
  const OrganizationAdminPanel({super.key});

  @override
  State<OrganizationAdminPanel> createState() => _OrganizationAdminPanelState();
}

class _OrganizationAdminPanelState extends State<OrganizationAdminPanel> {
  final OrganizationAdminService _service = OrganizationAdminService();
  final TextEditingController _partnerCompanyNameController =
    TextEditingController();
  final TextEditingController _partnerFirstNameController =
    TextEditingController();
  final TextEditingController _partnerLastNameController =
    TextEditingController();
  final TextEditingController _partnerEmailController = TextEditingController();
  final TextEditingController _partnerPhoneController = TextEditingController();
    final TextEditingController _partnerAddressLine1Controller =
      TextEditingController();
    final TextEditingController _partnerAddressLine2Controller =
      TextEditingController();
    final TextEditingController _partnerCityController = TextEditingController();
    final TextEditingController _partnerStateController = TextEditingController();
    final TextEditingController _partnerPostalCodeController =
      TextEditingController();
    final TextEditingController _partnerCountryController =
      TextEditingController(text: 'US');
  final TextEditingController _organizationNumberController =
      TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _licenseKeyController = TextEditingController();
  final TextEditingController _contactNameController = TextEditingController();
  final TextEditingController _contactEmailController = TextEditingController();
  final TextEditingController _contactPhoneController = TextEditingController();
  final TextEditingController _organizationNameFilterController =
      TextEditingController();
    final TextEditingController _partnerIdFilterController =
      TextEditingController();
    final TextEditingController _partnerNameFilterController =
      TextEditingController();
    final TextEditingController _locationNameController = TextEditingController();
    final TextEditingController _locationEmailController = TextEditingController();
    final TextEditingController _locationPhoneController = TextEditingController();
    final TextEditingController _locationAddressController = TextEditingController();
    final TextEditingController _locationAddress2Controller =
      TextEditingController();
    final TextEditingController _locationCityController = TextEditingController();
    final TextEditingController _locationStateController = TextEditingController();
    final TextEditingController _locationZipController = TextEditingController();
    final TextEditingController _locationTerminalLicensesController =
      TextEditingController(text: '1');

  bool _loading = true;
  bool _saving = false;
  bool _creatingPartner = false;
  bool _loadingLocations = false;
  bool _savingLocation = false;
  String? _editingId;
  String? _editingLocationId;
  String? _selectedPartnerId;
  String? _locationOrganizationId;
  String? _locationOrganizationNumber;
  String? _locationOrganizationLicenseKey;
  String? _message;
  List<OrganizationRecord> _organizations = const [];
  List<DistributionPartnerRecord> _partners = const [];
  List<LocationRecord> _locations = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _partnerCompanyNameController.dispose();
    _partnerFirstNameController.dispose();
    _partnerLastNameController.dispose();
    _partnerEmailController.dispose();
    _partnerPhoneController.dispose();
    _partnerAddressLine1Controller.dispose();
    _partnerAddressLine2Controller.dispose();
    _partnerCityController.dispose();
    _partnerStateController.dispose();
    _partnerPostalCodeController.dispose();
    _partnerCountryController.dispose();
    _organizationNumberController.dispose();
    _nameController.dispose();
    _licenseKeyController.dispose();
    _contactNameController.dispose();
    _contactEmailController.dispose();
    _contactPhoneController.dispose();
    _organizationNameFilterController.dispose();
    _partnerIdFilterController.dispose();
    _partnerNameFilterController.dispose();
    _locationNameController.dispose();
    _locationEmailController.dispose();
    _locationPhoneController.dispose();
    _locationAddressController.dispose();
    _locationAddress2Controller.dispose();
    _locationCityController.dispose();
    _locationStateController.dispose();
    _locationZipController.dispose();
    _locationTerminalLicensesController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _message = null;
    });

    try {
      final partners = await _service.listDistributionPartners();
      final rows = await _service.listOrganizations();
      if (!mounted) return;
      setState(() {
        _partners = partners;
        _organizations = rows;
        if (_selectedPartnerId != null &&
            !_partners.any((p) => p.partnerId == _selectedPartnerId)) {
          _selectedPartnerId = null;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = 'Failed to load organizations: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _loadForEdit(OrganizationRecord row) {
    setState(() {
      _editingId = row.id;
      _organizationNumberController.text = row.organizationNumber;
      _nameController.text = row.name;
      _licenseKeyController.text = row.licenseKey;
      _contactNameController.text = row.contactName;
      _contactEmailController.text = row.contactEmail;
      _contactPhoneController.text = row.contactPhone;
      _selectedPartnerId = row.partnerId.trim().isEmpty ? null : row.partnerId;
      _message = null;
    });
  }

  void _resetForm() {
    setState(() {
      _editingId = null;
      _organizationNumberController.clear();
      _nameController.clear();
      _licenseKeyController.clear();
      _contactNameController.clear();
      _contactEmailController.clear();
      _contactPhoneController.clear();
      _selectedPartnerId = null;
      _message = null;
    });
  }

  Future<void> _createPartner() async {
    final companyName = _partnerCompanyNameController.text.trim();
    if (companyName.isEmpty) {
      setState(() {
        _message = 'Partner company name is required.';
      });
      return;
    }

    setState(() {
      _creatingPartner = true;
      _message = null;
    });

    try {
      final partner = await _service.createDistributionPartner(
        companyName: companyName,
        contactFirstName: _partnerFirstNameController.text,
        contactLastName: _partnerLastNameController.text,
        email: _partnerEmailController.text,
        phone: _partnerPhoneController.text,
        addressLine1: _partnerAddressLine1Controller.text,
        addressLine2: _partnerAddressLine2Controller.text,
        city: _partnerCityController.text,
        state: _partnerStateController.text,
        postalCode: _partnerPostalCodeController.text,
        country: _partnerCountryController.text,
      );

      if (!mounted) return;

      setState(() {
        _partnerCompanyNameController.clear();
        _partnerFirstNameController.clear();
        _partnerLastNameController.clear();
        _partnerEmailController.clear();
        _partnerPhoneController.clear();
        _partnerAddressLine1Controller.clear();
        _partnerAddressLine2Controller.clear();
        _partnerCityController.clear();
        _partnerStateController.clear();
        _partnerPostalCodeController.clear();
        _partnerCountryController.text = 'US';
        _selectedPartnerId = partner.partnerId;
        _message =
          'Partner created: ${partner.partnerId} - ${partner.companyName}. '
          'Default login: ${partner.username} / Partner!${partner.partnerId}!';
      });

      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = 'Partner create failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _creatingPartner = false;
        });
      }
    }
  }

  String _generateLicenseKey() {
    final rng = Random();
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

    String token(int length) {
      final chars = List<String>.generate(
        length,
        (_) => alphabet[rng.nextInt(alphabet.length)],
      );
      return chars.join();
    }

    final orgNumber = _organizationNumberController.text.trim();
    final orgPart = orgNumber.isEmpty ? '000000' : orgNumber.padLeft(6, '0');
    return 'ORG-$orgPart-${token(4)}-${token(4)}';
  }

  Future<void> _save() async {
    final wasEditing = _editingId != null;
    final orgNumber = _organizationNumberController.text.trim();
    final name = _nameController.text.trim();

    if (!RegExp(r'^\d{6}$').hasMatch(orgNumber)) {
      setState(() {
        _message = 'Organization number must be exactly 6 digits.';
      });
      return;
    }

    if (name.isEmpty) {
      setState(() {
        _message = 'Organization name is required.';
      });
      return;
    }

    if ((_selectedPartnerId ?? '').trim().isEmpty) {
      setState(() {
        _message =
            'Create/select a distribution partner before saving an organization.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _message = null;
    });

    try {
      final saved = await _service.upsertOrganization(
        id: _editingId,
        organizationNumber: orgNumber,
        name: name,
        licenseKey: _licenseKeyController.text,
        contactName: _contactNameController.text,
        contactEmail: _contactEmailController.text,
        contactPhone: _contactPhoneController.text,
        partnerId: _selectedPartnerId ?? '',
      );

      if (!mounted) return;

      setState(() {
        if (wasEditing) {
          _editingId = saved.id;
          _licenseKeyController.text = saved.licenseKey;
          _message = saved.licenseKey.trim().isEmpty
              ? 'Organization updated and deactivated (blank license key).'
              : 'Organization updated and active.';
        } else {
          _editingId = null;
          _organizationNumberController.clear();
          _nameController.clear();
          _licenseKeyController.clear();
          _contactNameController.clear();
          _contactEmailController.clear();
          _contactPhoneController.clear();
            _selectedPartnerId = null;
          _message = saved.licenseKey.trim().isEmpty
              ? 'Organization created and deactivated (blank license key).'
              : 'Organization created and active.';
        }
      });

      await _refresh();
    } catch (error) {
      if (!mounted) return;
      final errorText = error.toString();
      setState(() {
        if (errorText.toLowerCase().contains('already exists')) {
          _message =
              'Organization number already exists. Use Edit for existing records.';
        } else {
          _message = 'Save failed: $error';
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  void _openLocations(OrganizationRecord organization) {
    _showLocationsDialog(organization);
  }

  Future<void> _showPartnersDialog() async {
    final companyNameController = TextEditingController();
    final firstNameController = TextEditingController();
    final lastNameController = TextEditingController();
    final emailController = TextEditingController();
    final phoneController = TextEditingController();
    final address1Controller = TextEditingController();
    final address2Controller = TextEditingController();
    final cityController = TextEditingController();
    final stateController = TextEditingController();
    final postalCodeController = TextEditingController();
    final countryController = TextEditingController(text: 'US');

    var loading = true;
    var saving = false;
    var showForm = false;
    var initialized = false;
    var editingPartnerId = '';
    var dialogMessage = '';
    var rows = <DistributionPartnerRecord>[];

    void resetForm(StateSetter setModalState) {
      setModalState(() {
        editingPartnerId = '';
        companyNameController.clear();
        firstNameController.clear();
        lastNameController.clear();
        emailController.clear();
        phoneController.clear();
        address1Controller.clear();
        address2Controller.clear();
        cityController.clear();
        stateController.clear();
        postalCodeController.clear();
        countryController.text = 'US';
      });
    }

    Future<void> loadRows(StateSetter setModalState) async {
      setModalState(() => loading = true);
      try {
        final response = await _service.listDistributionPartners();
        setModalState(() => rows = response);
      } catch (error) {
        setModalState(() => dialogMessage = 'Failed to load partners: $error');
      } finally {
        setModalState(() => loading = false);
      }
    }

    Future<void> saveRow(StateSetter setModalState) async {
      final companyName = companyNameController.text.trim();
      if (companyName.isEmpty) {
        setModalState(() => dialogMessage = 'Company name is required.');
        return;
      }
      if (editingPartnerId.isEmpty) {
        setModalState(() => dialogMessage = 'No partner selected for editing.');
        return;
      }

      setModalState(() {
        saving = true;
        dialogMessage = '';
      });

      try {
        await _service.updateDistributionPartner(
          id: editingPartnerId,
          companyName: companyName,
          contactFirstName: firstNameController.text,
          contactLastName: lastNameController.text,
          email: emailController.text,
          phone: phoneController.text,
          addressLine1: address1Controller.text,
          addressLine2: address2Controller.text,
          city: cityController.text,
          state: stateController.text,
          postalCode: postalCodeController.text,
          country: countryController.text,
        );
        setModalState(() {
          dialogMessage = 'Partner updated.';
          showForm = false;
        });
        resetForm(setModalState);
        await loadRows(setModalState);
        await _refresh();
      } catch (error) {
        setModalState(() => dialogMessage = 'Partner save failed: $error');
      } finally {
        setModalState(() => saving = false);
      }
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            if (!initialized) {
              initialized = true;
              Future<void>.microtask(() => loadRows(setModalState));
            }

            return Dialog(
              insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1020, maxHeight: 760),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Distribution Partners',
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: saving ? null : () => loadRows(setModalState),
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Refresh'),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: loading
                            ? const Center(child: CircularProgressIndicator())
                            : rows.isEmpty
                                ? const Center(child: Text('No partners yet.'))
                                : ListView.builder(
                                    itemCount: rows.length,
                                    itemBuilder: (context, index) {
                                      final row = rows[index];
                                      return Card(
                                        margin: const EdgeInsets.only(bottom: 6),
                                        child: ListTile(
                                          dense: true,
                                          visualDensity:
                                              const VisualDensity(vertical: -3),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 2,
                                          ),
                                          title: Text(
                                            '${row.partnerId} - ${row.companyName}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                          trailing: SizedBox(
                                            width: 70,
                                            child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.end,
                                              children: [
                                                IconButton(
                                                  tooltip: 'Copy partner number',
                                                  onPressed: saving
                                                      ? null
                                                      : () async {
                                                          await Clipboard.setData(
                                                            ClipboardData(
                                                              text: row.partnerId,
                                                            ),
                                                          );
                                                          if (!context.mounted) {
                                                            return;
                                                          }
                                                          ScaffoldMessenger.of(
                                                            context,
                                                          ).showSnackBar(
                                                            SnackBar(
                                                              content: Text(
                                                                'Copied partner number ${row.partnerId}',
                                                              ),
                                                            ),
                                                          );
                                                        },
                                                  iconSize: 18,
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      const BoxConstraints
                                                          .tightFor(
                                                    width: 28,
                                                    height: 28,
                                                  ),
                                                  icon: const Icon(
                                                    Icons.content_copy_rounded,
                                                  ),
                                                ),
                                                IconButton(
                                                  tooltip: 'Edit partner',
                                                  onPressed: saving
                                                      ? null
                                                      : () {
                                                          setModalState(() {
                                                            showForm = true;
                                                            editingPartnerId =
                                                                row.id;
                                                            companyNameController
                                                                    .text =
                                                                row.companyName;
                                                            firstNameController
                                                                    .text =
                                                                row.contactFirstName;
                                                            lastNameController
                                                                    .text =
                                                                row.contactLastName;
                                                            emailController.text =
                                                                row.email;
                                                            phoneController.text =
                                                                row.phone;
                                                            address1Controller
                                                                    .text =
                                                                row.addressLine1;
                                                            address2Controller
                                                                    .text =
                                                                row.addressLine2;
                                                            cityController.text =
                                                                row.city;
                                                            stateController.text =
                                                                row.state;
                                                            postalCodeController
                                                                    .text =
                                                                row.postalCode;
                                                            countryController
                                                                    .text =
                                                                row.country
                                                                        .isEmpty
                                                                    ? 'US'
                                                                    : row.country;
                                                            dialogMessage = '';
                                                          });
                                                        },
                                                  iconSize: 18,
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      const BoxConstraints
                                                          .tightFor(
                                                    width: 28,
                                                    height: 28,
                                                  ),
                                                  icon: const Icon(
                                                    Icons.edit_rounded,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                      ),
                      if (showForm) ...[
                        const Divider(height: 24),
                        Text(
                          'Edit Partner',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            SizedBox(
                              width: 280,
                              child: TextField(
                                controller: companyNameController,
                                decoration: const InputDecoration(labelText: 'Company Name'),
                              ),
                            ),
                            SizedBox(
                              width: 180,
                              child: TextField(
                                controller: firstNameController,
                                decoration: const InputDecoration(labelText: 'First Name'),
                              ),
                            ),
                            SizedBox(
                              width: 180,
                              child: TextField(
                                controller: lastNameController,
                                decoration: const InputDecoration(labelText: 'Last Name'),
                              ),
                            ),
                            SizedBox(
                              width: 240,
                              child: TextField(
                                controller: emailController,
                                decoration: const InputDecoration(labelText: 'Email'),
                              ),
                            ),
                            SizedBox(
                              width: 180,
                              child: TextField(
                                controller: phoneController,
                                decoration: const InputDecoration(labelText: 'Phone'),
                              ),
                            ),
                            SizedBox(
                              width: 300,
                              child: TextField(
                                controller: address1Controller,
                                decoration: const InputDecoration(labelText: 'Address Line 1'),
                              ),
                            ),
                            SizedBox(
                              width: 280,
                              child: TextField(
                                controller: address2Controller,
                                decoration: const InputDecoration(labelText: 'Address Line 2'),
                              ),
                            ),
                            SizedBox(
                              width: 180,
                              child: TextField(
                                controller: cityController,
                                decoration: const InputDecoration(labelText: 'City'),
                              ),
                            ),
                            SizedBox(
                              width: 100,
                              child: TextField(
                                controller: stateController,
                                decoration: const InputDecoration(labelText: 'State'),
                              ),
                            ),
                            SizedBox(
                              width: 140,
                              child: TextField(
                                controller: postalCodeController,
                                decoration: const InputDecoration(labelText: 'Postal Code'),
                              ),
                            ),
                            SizedBox(
                              width: 100,
                              child: TextField(
                                controller: countryController,
                                decoration: const InputDecoration(labelText: 'Country'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed: saving ? null : () => saveRow(setModalState),
                              icon: saving
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.save_rounded),
                              label: const Text('Save Partner'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: saving
                                  ? null
                                  : () {
                                      resetForm(setModalState);
                                      setModalState(() => showForm = false);
                                    },
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ],
                      if (dialogMessage.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: SelectableText(dialogMessage),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    companyNameController.dispose();
    firstNameController.dispose();
    lastNameController.dispose();
    emailController.dispose();
    phoneController.dispose();
    address1Controller.dispose();
    address2Controller.dispose();
    cityController.dispose();
    stateController.dispose();
    postalCodeController.dispose();
    countryController.dispose();
  }

  Future<void> _showLocationsDialog(OrganizationRecord organization) async {
    final nameController = TextEditingController();
    final emailController = TextEditingController();
    final phoneController = TextEditingController();
    final addressController = TextEditingController();
    final address2Controller = TextEditingController();
    final cityController = TextEditingController();
    final stateController = TextEditingController();
    final zipController = TextEditingController();
    final terminalLicensesController = TextEditingController(text: '1');

    var loading = true;
    var saving = false;
    var showForm = false;
    var initialized = false;
    var editingLocationId = '';
    var dialogMessage = '';
    var rows = <LocationRecord>[];

    void resetForm(StateSetter setModalState) {
      setModalState(() {
        editingLocationId = '';
        nameController.clear();
        emailController.clear();
        phoneController.clear();
        addressController.clear();
        address2Controller.clear();
        cityController.clear();
        stateController.clear();
        zipController.clear();
        terminalLicensesController.text = '1';
      });
    }

    Future<void> loadRows(StateSetter setModalState) async {
      setModalState(() {
        loading = true;
      });
      try {
        final response = await _service.listLocations(organizationId: organization.id);
        setModalState(() {
          rows = response;
        });
      } catch (error) {
        setModalState(() {
          dialogMessage = 'Failed to load locations: $error';
        });
      } finally {
        setModalState(() {
          loading = false;
        });
      }
    }

    Future<void> saveRow(StateSetter setModalState) async {
      final name = nameController.text.trim();
      final licenses = int.tryParse(terminalLicensesController.text.trim()) ?? -1;

      if (name.isEmpty) {
        setModalState(() {
          dialogMessage = 'Location name is required.';
        });
        return;
      }

      if (licenses < 0) {
        setModalState(() {
          dialogMessage = 'Terminal licenses cannot be negative.';
        });
        return;
      }

      setModalState(() {
        saving = true;
        dialogMessage = '';
      });

      try {
        await _service.upsertLocation(
          id: editingLocationId.isEmpty ? null : editingLocationId,
          organizationId: organization.id,
          name: name,
          email: emailController.text,
          phone: phoneController.text,
          address: addressController.text,
          address2: address2Controller.text,
          city: cityController.text,
          state: stateController.text,
          zip: zipController.text,
          terminalLicenses: licenses,
        );

        setModalState(() {
          dialogMessage = licenses == 0
              ? 'Location saved as inactive (terminal licenses = 0).'
              : 'Location saved.';
          showForm = false;
        });
        resetForm(setModalState);
        await loadRows(setModalState);
      } catch (error) {
        setModalState(() {
          dialogMessage = 'Location save failed: $error';
        });
      } finally {
        setModalState(() {
          saving = false;
        });
      }
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            if (!initialized) {
              initialized = true;
              Future<void>.microtask(() => loadRows(setModalState));
            }

            return Dialog(
              insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980, maxHeight: 760),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Managing Locations for ${organization.name}',
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          SizedBox(
                            width: 280,
                            child: InputDecorator(
                              decoration: const InputDecoration(labelText: 'Organization ID'),
                              child: SelectableText(organization.id),
                            ),
                          ),
                          SizedBox(
                            width: 180,
                            child: InputDecorator(
                              decoration: const InputDecoration(labelText: 'Organization Number'),
                              child: SelectableText(organization.organizationNumber),
                            ),
                          ),
                          SizedBox(
                            width: 280,
                            child: InputDecorator(
                              decoration: const InputDecoration(labelText: 'License Key'),
                              child: SelectableText(organization.licenseKey),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: saving
                                ? null
                                : () {
                                    resetForm(setModalState);
                                    setModalState(() {
                                      showForm = true;
                                      dialogMessage = '';
                                    });
                                  },
                            icon: const Icon(Icons.add_business_rounded),
                            label: const Text('Add Location'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: saving ? null : () => loadRows(setModalState),
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Refresh'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: loading
                            ? const Center(child: CircularProgressIndicator())
                            : rows.isEmpty
                                ? const Center(child: Text('No locations yet.'))
                                : ListView.builder(
                                    itemCount: rows.length,
                                    itemBuilder: (context, index) {
                                      final row = rows[index];
                                      return Card(
                                        margin: const EdgeInsets.only(bottom: 10),
                                        child: ListTile(
                                          title: Row(
                                            children: [
                                              Expanded(child: Text(row.name)),
                                              Chip(
                                                label: Text(
                                                  row.terminalLicenses == 0
                                                      ? 'Inactive'
                                                      : 'Active',
                                                ),
                                                backgroundColor: row.terminalLicenses == 0
                                                    ? const Color(0xFFFEE4E2)
                                                    : const Color(0xFFD1FADF),
                                              ),
                                            ],
                                          ),
                                          subtitle: Text(
                                            'Email: ${row.email} | Phone: ${row.phone}\n'
                                            'Address: ${row.address} ${row.address2}\n'
                                            'City/State/Zip: ${row.city}, ${row.state} ${row.zip}\n'
                                            'Terminal Licenses: ${row.terminalLicenses} | Active Terminals: ${row.terminalsActive}',
                                          ),
                                          isThreeLine: true,
                                          trailing: TextButton.icon(
                                            onPressed: saving
                                                ? null
                                                : () {
                                                    setModalState(() {
                                                      showForm = true;
                                                      editingLocationId = row.id;
                                                      nameController.text = row.name;
                                                      emailController.text = row.email;
                                                      phoneController.text = row.phone;
                                                      addressController.text = row.address;
                                                      address2Controller.text = row.address2;
                                                      cityController.text = row.city;
                                                      stateController.text = row.state;
                                                      zipController.text = row.zip;
                                                      terminalLicensesController.text =
                                                          row.terminalLicenses.toString();
                                                      dialogMessage = '';
                                                    });
                                                  },
                                            icon: const Icon(Icons.edit_location_alt_rounded),
                                            label: const Text('Edit'),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                      ),
                      if (showForm) ...[
                        const Divider(height: 24),
                        Text(
                          editingLocationId.isEmpty ? 'Add Location' : 'Edit Location',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            SizedBox(
                              width: 240,
                              child: TextField(
                                controller: nameController,
                                decoration: const InputDecoration(labelText: 'Location Name'),
                              ),
                            ),
                            SizedBox(
                              width: 220,
                              child: TextField(
                                controller: emailController,
                                decoration: const InputDecoration(labelText: 'Email'),
                              ),
                            ),
                            SizedBox(
                              width: 180,
                              child: TextField(
                                controller: phoneController,
                                decoration: const InputDecoration(labelText: 'Phone'),
                              ),
                            ),
                            SizedBox(
                              width: 280,
                              child: TextField(
                                controller: addressController,
                                decoration: const InputDecoration(labelText: 'Address'),
                              ),
                            ),
                            SizedBox(
                              width: 220,
                              child: TextField(
                                controller: address2Controller,
                                decoration: const InputDecoration(labelText: 'Address 2'),
                              ),
                            ),
                            SizedBox(
                              width: 160,
                              child: TextField(
                                controller: cityController,
                                decoration: const InputDecoration(labelText: 'City'),
                              ),
                            ),
                            SizedBox(
                              width: 100,
                              child: TextField(
                                controller: stateController,
                                decoration: const InputDecoration(labelText: 'State'),
                              ),
                            ),
                            SizedBox(
                              width: 120,
                              child: TextField(
                                controller: zipController,
                                decoration: const InputDecoration(labelText: 'Zip'),
                              ),
                            ),
                            SizedBox(
                              width: 220,
                              child: TextField(
                                controller: terminalLicensesController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Terminal Licenses (0 = inactive)',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed: saving ? null : () => saveRow(setModalState),
                              icon: saving
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.save_rounded),
                              label: const Text('Save Location'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: saving
                                  ? null
                                  : () {
                                      resetForm(setModalState);
                                      setModalState(() {
                                        showForm = false;
                                      });
                                    },
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Receipt signature message is defaulted and read-only here.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      if (dialogMessage.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: SelectableText(dialogMessage),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    nameController.dispose();
    emailController.dispose();
    phoneController.dispose();
    addressController.dispose();
    address2Controller.dispose();
    cityController.dispose();
    stateController.dispose();
    zipController.dispose();
    terminalLicensesController.dispose();
  }

  Future<void> _refreshLocations() async {
    final organizationId = (_locationOrganizationId ?? '').trim();
    if (organizationId.isEmpty) {
      return;
    }

    setState(() {
      _loadingLocations = true;
    });

    try {
      final rows = await _service.listLocations(organizationId: organizationId);
      if (!mounted) return;
      setState(() {
        _locations = rows;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = 'Failed to load locations: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingLocations = false;
        });
      }
    }
  }

  void _resetLocationForm() {
    setState(() {
      _editingLocationId = null;
      _locationNameController.clear();
      _locationEmailController.clear();
      _locationPhoneController.clear();
      _locationAddressController.clear();
      _locationAddress2Controller.clear();
      _locationCityController.clear();
      _locationStateController.clear();
      _locationZipController.clear();
      _locationTerminalLicensesController.text = '1';
    });
  }

  void _loadLocationForEdit(LocationRecord row) {
    setState(() {
      _editingLocationId = row.id;
      _locationNameController.text = row.name;
      _locationEmailController.text = row.email;
      _locationPhoneController.text = row.phone;
      _locationAddressController.text = row.address;
      _locationAddress2Controller.text = row.address2;
      _locationCityController.text = row.city;
      _locationStateController.text = row.state;
      _locationZipController.text = row.zip;
      _locationTerminalLicensesController.text =
          row.terminalLicenses.toString();
    });
  }

  Future<void> _saveLocation() async {
    final organizationId = (_locationOrganizationId ?? '').trim();
    if (organizationId.isEmpty) {
      setState(() {
        _message = 'Select an organization first to manage locations.';
      });
      return;
    }

    final name = _locationNameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _message = 'Location name is required.';
      });
      return;
    }

    final licenses =
        int.tryParse(_locationTerminalLicensesController.text.trim()) ?? 0;
    if (licenses < 0) {
      setState(() {
        _message = 'Terminal licenses cannot be negative.';
      });
      return;
    }

    setState(() {
      _savingLocation = true;
      _message = null;
    });

    try {
      await _service.upsertLocation(
        id: _editingLocationId,
        organizationId: organizationId,
        name: name,
        email: _locationEmailController.text,
        phone: _locationPhoneController.text,
        address: _locationAddressController.text,
        address2: _locationAddress2Controller.text,
        city: _locationCityController.text,
        state: _locationStateController.text,
        zip: _locationZipController.text,
        terminalLicenses: licenses,
      );

      if (!mounted) return;

      setState(() {
        _message = _editingLocationId == null
            ? 'Location created.'
            : 'Location updated.';
        if (licenses == 0) {
          _message = 'Location saved as inactive (terminal licenses set to 0).';
        }
      });

      _resetLocationForm();
      await _refreshLocations();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = 'Location save failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingLocation = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final wideColumns = MediaQuery.sizeOf(context).width >= 1280;
    final nameFilter = _organizationNameFilterController.text.trim().toLowerCase();
    final partnerIdFilter = _partnerIdFilterController.text.trim().toLowerCase();
    final partnerNameFilter = _partnerNameFilterController.text.trim().toLowerCase();
    final filteredOrganizations = _organizations.where((row) {
      if (nameFilter.isNotEmpty && !row.name.toLowerCase().contains(nameFilter)) {
        return false;
      }
      if (partnerIdFilter.isNotEmpty &&
          !row.partnerId.toLowerCase().contains(partnerIdFilter)) {
        return false;
      }
      if (partnerNameFilter.isNotEmpty &&
          !row.partnerCompanyName.toLowerCase().contains(partnerNameFilter)) {
        return false;
      }
      return true;
    }).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final leftColumn = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Distribution Partners',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SizedBox(
                      width: 220,
                      child: TextField(
                        controller: _partnerCompanyNameController,
                        decoration: const InputDecoration(
                          labelText: 'Partner Company Name',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 140,
                      child: TextField(
                        controller: _partnerFirstNameController,
                        decoration: const InputDecoration(
                          labelText: 'First Name',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 140,
                      child: TextField(
                        controller: _partnerLastNameController,
                        decoration: const InputDecoration(
                          labelText: 'Last Name',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 180,
                      child: TextField(
                        controller: _partnerEmailController,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 140,
                      child: TextField(
                        controller: _partnerPhoneController,
                        decoration: const InputDecoration(
                          labelText: 'Phone',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: TextField(
                        controller: _partnerAddressLine1Controller,
                        decoration: const InputDecoration(
                          labelText: 'Address 1',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 180,
                      child: TextField(
                        controller: _partnerAddressLine2Controller,
                        decoration: const InputDecoration(
                          labelText: 'Address 2',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 120,
                      child: TextField(
                        controller: _partnerCityController,
                        decoration: const InputDecoration(
                          labelText: 'City',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: _partnerStateController,
                        decoration: const InputDecoration(
                          labelText: 'State',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _partnerPostalCodeController,
                        decoration: const InputDecoration(
                          labelText: 'Postal',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: _partnerCountryController,
                        decoration: const InputDecoration(
                          labelText: 'Country',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: (_saving || _creatingPartner)
                          ? null
                          : _createPartner,
                      icon: _creatingPartner
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.business_center_rounded, size: 16),
                      label: const Text('Create'),
                    ),
                    OutlinedButton.icon(
                      onPressed: (_saving || _creatingPartner)
                          ? null
                          : _showPartnersDialog,
                      icon: const Icon(Icons.people_alt_rounded, size: 16),
                      label: const Text('Manage'),
                    ),
                    if (_partners.isNotEmpty)
                      Text(
                        '${_partners.length} partner(s)',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Partner username/password are auto-generated on create.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                if (_partners.isEmpty)
                  Text(
                    'No partners yet.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  )
                else
                  SizedBox(
                    height: 320,
                    child: ListView.builder(
                      itemCount: _partners.length,
                      itemBuilder: (context, index) {
                        final row = _partners[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 6),
                          child: ListTile(
                            dense: true,
                            visualDensity: const VisualDensity(vertical: -3),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 2,
                            ),
                            title: Text(
                              '${row.partnerId} - ${row.companyName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            trailing: SizedBox(
                              width: 70,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  IconButton(
                                    tooltip: 'Copy partner number',
                                    onPressed: () async {
                                      await Clipboard.setData(
                                        ClipboardData(text: row.partnerId),
                                      );
                                    },
                                    iconSize: 18,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints.tightFor(
                                      width: 28,
                                      height: 28,
                                    ),
                                    icon: const Icon(Icons.content_copy_rounded),
                                  ),
                                  IconButton(
                                    tooltip: 'Manage partners',
                                    onPressed: _showPartnersDialog,
                                    iconSize: 18,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints.tightFor(
                                      width: 28,
                                      height: 28,
                                    ),
                                    icon: const Icon(Icons.edit_rounded),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            );

            final rightColumn = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _editingId == null ? 'Create Organization' : 'Edit Organization',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SizedBox(
                      width: 150,
                      child: TextField(
                        controller: _organizationNumberController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Org Number',
                          hintText: '6 digits',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 230,
                      child: DropdownButtonFormField<String>(
                        initialValue: (_selectedPartnerId ?? '').isEmpty
                            ? null
                            : _selectedPartnerId,
                        decoration: const InputDecoration(
                          labelText: 'Distribution Partner',
                          isDense: true,
                        ),
                        items: _partners
                            .map(
                              (p) => DropdownMenuItem<String>(
                                value: p.partnerId,
                                child: Text(p.displayLabel),
                              ),
                            )
                            .toList(),
                        onChanged: _saving
                            ? null
                            : (value) {
                                setState(() {
                                  _selectedPartnerId = value;
                                });
                              },
                      ),
                    ),
                    SizedBox(
                      width: 240,
                      child: TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Organization Name',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 240,
                      child: TextField(
                        controller: _licenseKeyController,
                        decoration: const InputDecoration(
                          labelText: 'License Key',
                          hintText: 'Blank = inactive',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 180,
                      child: TextField(
                        controller: _contactNameController,
                        decoration: const InputDecoration(
                          labelText: 'Contact Name',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: TextField(
                        controller: _contactEmailController,
                        decoration: const InputDecoration(
                          labelText: 'Contact Email',
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 170,
                      child: TextField(
                        controller: _contactPhoneController,
                        decoration: const InputDecoration(
                          labelText: 'Contact Phone',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _saving
                          ? null
                          : () {
                              _licenseKeyController.text = _generateLicenseKey();
                            },
                      icon: const Icon(Icons.vpn_key_rounded, size: 16),
                      label: const Text('Generate Key'),
                    ),
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_rounded, size: 16),
                      label: Text(
                        _editingId == null ? 'Save Org' : 'Save Changes',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _saving ? null : _resetForm,
                      icon: const Icon(Icons.clear_rounded, size: 16),
                      label: const Text('Clear'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _saving ? null : _refresh,
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Refresh'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Blank license key deactivates organization.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                if (_message != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(_message!, style: theme.textTheme.bodySmall),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  'Organizations',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SizedBox(
                      width: 220,
                      child: TextField(
                        controller: _organizationNameFilterController,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Org Name',
                          prefixIcon: Icon(Icons.search_rounded, size: 16),
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 170,
                      child: TextField(
                        controller: _partnerIdFilterController,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Partner ID',
                          prefixIcon: Icon(Icons.filter_alt_rounded, size: 16),
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 210,
                      child: TextField(
                        controller: _partnerNameFilterController,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Partner Name',
                          prefixIcon: Icon(Icons.filter_alt_rounded, size: 16),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${filteredOrganizations.length} organization(s)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_organizations.isEmpty)
                  Text(
                    'No organizations found yet.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  )
                else if (filteredOrganizations.isEmpty)
                  Text(
                    'No organizations match the current filters.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  )
                else
                  SizedBox(
                    height: 320,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 5,
                                child: Text(
                                  'Organization',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  'Partner ID',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Expanded(
                                flex: 3,
                                child: Text(
                                  'Partner Name',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 70),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        Expanded(
                          child: ListView.builder(
                            itemCount: filteredOrganizations.length,
                            itemBuilder: (context, index) {
                              final row = filteredOrganizations[index];

                              return Card(
                                margin: const EdgeInsets.only(bottom: 6),
                                child: ListTile(
                                  onTap: () => _openLocations(row),
                                  dense: true,
                                  visualDensity:
                                      const VisualDensity(vertical: -3),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 2,
                                  ),
                                  title: Row(
                                    children: [
                                      Expanded(
                                        flex: 5,
                                        child: Text(
                                          '${row.organizationNumber} - ${row.name}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                      ),
                                      Expanded(
                                        flex: 2,
                                        child: Text(
                                          row.partnerId.isEmpty
                                              ? '-'
                                              : row.partnerId,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(fontSize: 12),
                                        ),
                                      ),
                                      Expanded(
                                        flex: 3,
                                        child: Text(
                                          row.partnerCompanyName.isEmpty
                                              ? '(not set)'
                                              : row.partnerCompanyName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(fontSize: 12),
                                        ),
                                      ),
                                    ],
                                  ),
                                  trailing: SizedBox(
                                    width: 70,
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        IconButton(
                                          tooltip: 'View locations',
                                          onPressed: () => _openLocations(row),
                                          iconSize: 18,
                                          padding: EdgeInsets.zero,
                                          constraints:
                                              const BoxConstraints.tightFor(
                                            width: 28,
                                            height: 28,
                                          ),
                                          icon:
                                              const Icon(Icons.place_rounded),
                                        ),
                                        IconButton(
                                          tooltip: 'Edit organization',
                                          onPressed: () => _loadForEdit(row),
                                          iconSize: 18,
                                          padding: EdgeInsets.zero,
                                          constraints:
                                              const BoxConstraints.tightFor(
                                            width: 28,
                                            height: 28,
                                          ),
                                          icon: const Icon(Icons.edit_rounded),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );

            if (!wideColumns) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  leftColumn,
                  const SizedBox(height: 12),
                  rightColumn,
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: leftColumn),
                const SizedBox(width: 12),
                Expanded(child: rightColumn),
              ],
            );
          },
        ),
        if ((_locationOrganizationId ?? '').isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            'Locations for Organization ${_locationOrganizationNumber ?? ''}',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 260,
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Organization ID'),
                  child: SelectableText(_locationOrganizationId ?? ''),
                ),
              ),
              SizedBox(
                width: 180,
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Organization Number'),
                  child: SelectableText(_locationOrganizationNumber ?? ''),
                ),
              ),
              SizedBox(
                width: 260,
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'License Key'),
                  child: SelectableText(_locationOrganizationLicenseKey ?? ''),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _locationNameController,
                  decoration: const InputDecoration(labelText: 'Location Name'),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _locationEmailController,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
              ),
              SizedBox(
                width: 180,
                child: TextField(
                  controller: _locationPhoneController,
                  decoration: const InputDecoration(labelText: 'Phone'),
                ),
              ),
              SizedBox(
                width: 320,
                child: TextField(
                  controller: _locationAddressController,
                  decoration: const InputDecoration(labelText: 'Address'),
                ),
              ),
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _locationAddress2Controller,
                  decoration: const InputDecoration(labelText: 'Address 2'),
                ),
              ),
              SizedBox(
                width: 180,
                child: TextField(
                  controller: _locationCityController,
                  decoration: const InputDecoration(labelText: 'City'),
                ),
              ),
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _locationStateController,
                  decoration: const InputDecoration(labelText: 'State'),
                ),
              ),
              SizedBox(
                width: 140,
                child: TextField(
                  controller: _locationZipController,
                  decoration: const InputDecoration(labelText: 'Zip'),
                ),
              ),
              SizedBox(
                width: 180,
                child: TextField(
                  controller: _locationTerminalLicensesController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Terminal Licenses (0 = inactive)',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _savingLocation ? null : _saveLocation,
                icon: _savingLocation
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_business_rounded),
                label: Text(
                  _editingLocationId == null ? 'Create Location' : 'Save Location',
                ),
              ),
              OutlinedButton.icon(
                onPressed: _savingLocation ? null : _resetLocationForm,
                icon: const Icon(Icons.clear_rounded),
                label: const Text('Clear Location Form'),
              ),
              OutlinedButton.icon(
                onPressed: _savingLocation ? null : _refreshLocations,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Refresh Locations'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Receipt signature message is auto-set to default and read-only in this flow.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          if (_loadingLocations)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_locations.isEmpty)
            Text(
              'No locations found yet for this organization.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            )
          else
            SizedBox(
              height: 300,
              child: ListView.builder(
                itemCount: _locations.length,
                itemBuilder: (context, index) {
                  final row = _locations[index];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      title: Row(
                        children: [
                          Expanded(child: Text(row.name)),
                          Chip(
                            label: Text(
                              row.terminalLicenses == 0 ? 'Inactive' : 'Active',
                            ),
                            backgroundColor: row.terminalLicenses == 0
                                ? const Color(0xFFFEE4E2)
                                : const Color(0xFFD1FADF),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        'Email: ${row.email} | Phone: ${row.phone}\n'
                        'Address: ${row.address} ${row.address2}\n'
                        'City/State/Zip: ${row.city}, ${row.state} ${row.zip}\n'
                        'Terminal Licenses: ${row.terminalLicenses} | Active: ${row.terminalsActive}',
                      ),
                      isThreeLine: true,
                      trailing: IconButton(
                        tooltip: 'Edit location',
                        onPressed: () => _loadLocationForEdit(row),
                        icon: const Icon(Icons.edit_location_alt_rounded),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ],
    );
  }
}
