part of '../action.dart';

@Riverpod(keepAlive: true)
class ProfilesAction extends _$ProfilesAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  @override
  void build() {}

  final _managedWork = SerialTaskScheduler();
  static const _protection = ManagedIspPlatform();

  Future<void> createManagedIsp(ManagedIspProfile input) {
    return _managedWork.run(() async {
      if (!system.isMacOS || ref.read(safeModeProvider)) {
        throw StateError('Managed ISP is unavailable in this build.');
      }
      final profiles = ref.read(profilesProvider);
      final source =
          profiles
              .where(
                (item) =>
                    item.type == ProfileType.url &&
                    item.url == input.subscription.toString(),
              )
              .firstOrNull ??
          Profile.normal(
            label: currentAppLocalizations.managedIspPure,
            url: input.subscription.toString(),
          );
      final existing = profiles
          .where((item) => managedIspSourceId(item.url) == source.id)
          .firstOrNull;
      if (existing != null &&
          await _protection.protectedProfile == existing.id) {
        throw StateError(
          'Switch to the VPN subscription to update ISP credentials.',
        );
      }
      final managed =
          existing ??
          Profile.normal(
            label: currentAppLocalizations.managedIspMode,
          ).copyWith(url: managedIspUrl(source.id), autoUpdate: false);

      final staged = await _downloadManagedSource(source);
      final sourceFile = await staged.file;
      var stored = false;
      try {
        final raw = await _core.readConfig(staged.id);
        final pins = await input.resolve(raw);
        input.protectedConfig(
          raw,
          pins,
          tun: managedIspTun,
          mixedPort: 7890,
          enableTun: true,
        );
        final marker = await managed.file;
        await marker.writeAsStringAtomically('rules: [ "MATCH,REJECT" ]\n');
        final digest = await fileSha256(sourceFile.path);
        final previous = existing == null
            ? null
            : await _protection.load(managed.id);
        await _protection.save(
          managed.id,
          input.storage(
            digest: digest,
            addresses: pins,
            previous: previous?['snapshot'] is Map
                ? Map<String, Object?>.from(previous!['snapshot'] as Map)
                : null,
          ),
        );
        stored = true;
        final current = ref.read(profilesProvider).getProfile(source.id);
        if (profiles.getProfile(source.id) != null &&
            current?.url != source.url) {
          throw StateError('The subscription was edited during the download.');
        }
        await sourceFile.rename((await source.file).path);
        final updated = (current ?? source).copyWith(
          lastUpdateDate: staged.lastUpdateDate,
          subscriptionInfo: staged.subscriptionInfo,
        );
        final provider = ref.read(profilesProvider.notifier);
        final newSource = provider.labeled(updated);
        final newManaged = provider.labeled(
          managed.copyWith(lastUpdateDate: staged.lastUpdateDate),
        );
        await database.profilesDao.putAll([
          newSource.toCompanion(),
          newManaged.toCompanion(),
        ]);
        provider.put(newSource);
        provider.put(newManaged);
        if (ref.read(currentProfileIdProvider) == null) {
          ref.read(currentProfileIdProvider.notifier).value = newSource.id;
        }
      } catch (_) {
        if (existing == null && stored) await _protection.remove(managed.id);
        rethrow;
      } finally {
        await sourceFile.safeDelete();
      }
    });
  }

  Future<Profile> _downloadManagedSource(
    Profile source, {
    bool protected = false,
  }) async {
    final staged = Profile.normal(url: source.url);
    try {
      final (bytes, info) = await _readManagedEndpoint(
        Uri.parse(source.url),
        protected: protected,
        maxBytes: 16 << 20,
      );
      final updated = await staged.saveFile(
        decompressUnlabeled(bytes),
        validate: (path, key) => _core.validateProfile(path, key),
      );
      return updated.copyWith(
        subscriptionInfo: SubscriptionInfo.formHString(info),
      );
    } catch (_) {
      await (await staged.file).safeDelete();
      throw const FormatException(
        'The VPN subscription could not be downloaded or parsed.',
      );
    }
  }

  Future<(Uint8List, String?)> _readManagedEndpoint(
    Uri url, {
    required bool protected,
    int maxBytes = 65536,
    String? accept,
  }) async {
    final port = ref.read(patchClashConfigProvider).mixedPort;
    if (protected && !isUsableMixedPort(port)) {
      throw StateError('The protected connection is unavailable.');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = globalState.ua;
    if (protected) client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    try {
      for (var attempt = 0; attempt < 4; attempt++) {
        if (url.scheme != 'https' ||
            url.host.isEmpty ||
            url.userInfo.isNotEmpty) {
          break;
        }
        final request = await client
            .getUrl(url)
            .timeout(const Duration(seconds: 12));
        request.followRedirects = false;
        if (accept != null) {
          request.headers.set(HttpHeaders.acceptHeader, accept);
        }
        final response = await request.close().timeout(
          const Duration(seconds: 12),
        );
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (response.isRedirect && location != null) {
          await response.drain<void>().timeout(const Duration(seconds: 5));
          url = url.resolve(location);
          continue;
        }
        if (response.statusCode != HttpStatus.ok) break;
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(
          const Duration(seconds: 12),
        )) {
          bytes.add(chunk);
          if (bytes.length > maxBytes) {
            throw const FormatException('The response is too large.');
          }
        }
        return (
          bytes.takeBytes(),
          response.headers.value('subscription-userinfo'),
        );
      }
      throw StateError('The endpoint rejected the HTTPS request.');
    } finally {
      client.close(force: true);
    }
  }

  Future<List<String>> _resolveThroughManagedIsp(String host) async {
    final (bytes, _) = await _readManagedEndpoint(
      Uri.https('1.1.1.1', '/dns-query', {'name': host, 'type': 'A'}),
      protected: true,
      accept: 'application/dns-json',
    );
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map ||
        decoded['Status'] != 0 ||
        decoded['Answer'] is! List) {
      throw const FormatException('The upstream host could not be resolved.');
    }
    return [
      for (final answer in decoded['Answer'] as List)
        if (answer is Map && answer['type'] == 1 && answer['data'] is String)
          answer['data'] as String,
    ];
  }

  Future<String> verifyManagedIsp(Profile profile) async {
    if (await _protection.protectedProfile != profile.id ||
        !ref.read(isStartProvider) ||
        ref.read(currentProfileIdProvider) != profile.id) {
      throw StateError('The protected profile is not running.');
    }
    final (bytes, _) = await _readManagedEndpoint(
      Uri.parse(managedIspHealthCheck),
      protected: true,
    );
    final lines = utf8.decode(bytes).split('\n');
    final address = lines
        .where((line) => line.startsWith('ip='))
        .firstOrNull
        ?.substring(3);
    if (address == null || InternetAddress.tryParse(address) == null) {
      throw StateError('The fixed exit could not be checked.');
    }
    final expected = (await _protection.load(profile.id))?['expectedIp'];
    if (expected is String &&
        InternetAddress.tryParse(expected) !=
            InternetAddress.tryParse(address)) {
      throw StateError('The observed exit does not match the expected IP.');
    }
    return address;
  }

  Future<void> selectProfile(int? id) {
    final existing = ref.read(profilesProvider);
    if (!existing.any((item) => managedIspSourceId(item.url) != null)) {
      ref.read(currentProfileIdProvider.notifier).value = id;
      return Future<void>.value();
    }
    return _managedWork.run(() async {
      final profiles = ref.read(profilesProvider);
      final target = profiles.getProfile(id);
      final current = ref.read(currentProfileProvider);
      final managed = managedIspSourceId(target?.url ?? '');
      final previousManaged = managedIspSourceId(current?.url ?? '');
      if (managed == null && (!system.isMacOS || ref.read(safeModeProvider))) {
        ref.read(currentProfileIdProvider.notifier).value = id;
        return;
      }
      final armed = await _protection.protectedProfile;
      if (managed == null && armed == null && previousManaged == null) {
        ref.read(currentProfileIdProvider.notifier).value = id;
        return;
      }
      if (managed != null && !await _protection.available) {
        throw StateError(currentAppLocalizations.managedIspUnavailable);
      }
      final setup = ref.read(setupActionProvider.notifier);
      if (managed == null &&
          armed != null &&
          id != await _protection.protectedSource) {
        throw StateError(currentAppLocalizations.managedIspExitViaPure);
      }
      if (managed != null && armed != null && armed != id) {
        throw StateError(currentAppLocalizations.managedIspExitViaPure);
      }
      await setup.changeManagedSelection(
        target,
        releaseProtection: managed == null && armed != null,
      );
      if (managed != null) {
        final started = await setup.setRunning(true, initialize: true);
        if (!started) {
          throw StateError(currentAppLocalizations.managedIspBlocked);
        }
      } else {
        await setup.setRunning(true, initialize: true);
      }
    });
  }

  Future<void> refreshManagedIsp(Profile profile) async {
    final sourceId = managedIspSourceId(profile.url);
    final source = ref.read(profilesProvider).getProfile(sourceId);
    if (source != null) await updateProfile(source, showLoading: true);
  }

  Future<void> _updateManagedSource(Profile source, Profile managed) async {
    await _managedWork.run(() async {
      final active = await _protection.protectedProfile;
      if (active != null && active != managed.id) {
        throw StateError('Another fixed ISP profile is protected.');
      }
      final rawStorage = await _protection.load(managed.id);
      if (rawStorage == null) {
        throw StateError('Fixed ISP credentials are missing.');
      }
      final input = ManagedIspProfile.fromStorage(
        Uri.parse(source.url),
        rawStorage,
      );
      final staged = await _downloadManagedSource(
        source,
        protected: active != null,
      );
      final file = await staged.file;
      try {
        final raw = await _core.readConfig(staged.id);
        final sourceDigest = await fileSha256((await source.file).path);
        final previous = _managedIspAddresses(rawStorage, sourceDigest);
        final pins = await input.resolve(
          raw,
          previous: previous,
          resolver: active != null ? _resolveThroughManagedIsp : null,
        );
        input.protectedConfig(
          raw,
          pins,
          tun: managedIspTun,
          mixedPort: 7890,
          enableTun: true,
        );
        final latest = ref.read(profilesProvider).getProfile(source.id);
        if (latest == null ||
            latest.url != source.url ||
            ref.read(profilesProvider).getProfile(managed.id) == null) {
          return;
        }
        await _protection.save(
          managed.id,
          input.storage(
            digest: await fileSha256(file.path),
            addresses: pins,
            previous: {'digest': sourceDigest, 'addresses': previous},
          ),
        );
        await file.rename((await latest.file).path);
        final provider = ref.read(profilesProvider.notifier);
        provider.put(
          latest.copyWith(
            lastUpdateDate: staged.lastUpdateDate,
            subscriptionInfo: staged.subscriptionInfo,
          ),
        );
        provider.put(managed.copyWith(lastUpdateDate: staged.lastUpdateDate));
        final selected = ref.read(currentProfileIdProvider);
        if (selected == managed.id || selected == source.id) {
          ref
              .read(setupActionProvider.notifier)
              .applyProfileDebounce(silence: true, force: true);
        }
      } finally {
        await file.safeDelete();
      }
    });
  }

  void updateCurrentSelectedMap(String groupName, String proxyName) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile != null &&
        currentProfile.selectedMap[groupName] != proxyName) {
      final selectedMap = Map<String, String>.from(currentProfile.selectedMap)
        ..[groupName] = proxyName;
      ref
          .read(profilesProvider.notifier)
          .put(currentProfile.copyWith(selectedMap: selectedMap));
    }
  }

  /// An empty [proxyName] forgets the group's pick.
  void setSelection(int profileId, String groupName, String proxyName) {
    final profile = ref.read(profilesProvider).getProfile(profileId);
    if (profile == null ||
        (profile.selectedMap[groupName] ?? '') == proxyName) {
      return;
    }
    final selectedMap = Map<String, String>.from(profile.selectedMap);
    if (proxyName.isEmpty) {
      selectedMap.remove(groupName);
    } else {
      selectedMap[groupName] = proxyName;
    }
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(selectedMap: selectedMap));
  }

  Future<void> deleteProfile(int id) async {
    final profiles = ref.read(profilesProvider);
    final profile = profiles.getProfile(id);
    final source = managedIspSourceId(profile?.url ?? '');
    if (system.isMacOS && !ref.read(safeModeProvider)) {
      final protected = await _protection.protectedProfile;
      if (protected != null &&
          (protected == id || id == await _protection.protectedSource)) {
        throw StateError(currentAppLocalizations.managedIspExitViaPure);
      }
      if (profiles.any((item) => managedIspSourceId(item.url) == id)) {
        throw StateError(currentAppLocalizations.managedIspRemovePairFirst);
      }
      if (source != null) await _protection.remove(id);
    }
    await ref.read(profilesProvider.notifier).del(id);
    await clearEffect(id);
    final currentProfileId = ref.read(currentProfileIdProvider);
    if (currentProfileId == id) {
      final profiles = ref.read(profilesProvider);
      if (profiles.isNotEmpty) {
        final updateId = profiles.first.id;
        ref.read(currentProfileIdProvider.notifier).value = updateId;
      } else {
        ref.read(currentProfileIdProvider.notifier).value = null;
        unawaited(ref.read(setupActionProvider.notifier).setRunning(false));
      }
    }
  }

  Future<String?> validateConfigWithData(List<int> data) async {
    return _core.validateConfigWithData(data);
  }

  Future<void> autoUpdateProfiles() async {
    for (final id in [
      for (final profile in ref.read(profilesProvider)) profile.id,
    ]) {
      final profile = ref.read(profilesProvider).getProfile(id);
      if (profile == null || !profile.autoUpdate) continue;
      final isNotNeedUpdate = profile.lastUpdateDate
          ?.add(profile.autoUpdateDuration)
          .isBeforeNow;
      if (isNotNeedUpdate == false || profile.type != ProfileType.url) {
        continue;
      }
      try {
        await updateProfile(profile);
      } catch (e) {
        commonPrint.log(compactError(e), logLevel: LogLevel.warning);
      }
    }
  }

  void putProfile(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (ref.read(currentProfileIdProvider) != null) return;
    ref.read(currentProfileIdProvider.notifier).value = profile.id;
  }

  Future<List<Profile>> providerUsers(Profile profile) async {
    if (profile.type == ProfileType.custom) {
      return const [];
    }
    final users = await ref
        .read(clashProvidersActionProvider.notifier)
        .profilesReferencing(ProviderKind.proxy, profile.realLabel);
    return [
      for (final user in users)
        if (user.id != profile.id) user,
    ];
  }

  /// Where a profile's own group takes a name, the name stands for that group.
  Future<List<Profile>> proxyUsers(Set<String> names) async {
    final (ruleTargets, dialerTargets) = await (
      database.rulesDao.targetsNaming(names),
      database.proxyDialersDao.targetsNaming(names),
    ).wait;
    final users = <Profile>[];
    for (final profile in ref.read(profilesProvider)) {
      if (profile.type != ProfileType.custom) {
        continue;
      }
      final groups = await database.proxyGroupsDao.query(profile.id).get();
      final inUse = proxyNamesInUse(
        names.difference({for (final group in groups) group.name}),
        groups: groups,
        ruleTargets: ruleTargets[profile.id] ?? const {},
        dialerTargets: dialerTargets[profile.id] ?? const {},
        overrides: profile.overrides,
      );
      if (inUse.isNotEmpty) {
        users.add(profile);
      }
    }
    return users;
  }

  Future<Set<String>> groupsInUse(int profileId, Set<int> groupIds) async {
    final groups = await database.proxyGroupsDao.query(profileId).get();
    final names = {
      for (final group in groups)
        if (groupIds.contains(group.id)) group.name,
    };
    final (ruleTargets, dialerTargets) = await (
      database.rulesDao.targetsNaming(names),
      database.proxyDialersDao.targetsNaming(names),
    ).wait;
    return proxyNamesInUse(
      names,
      groups: groups.where((group) => !groupIds.contains(group.id)),
      ruleTargets: ruleTargets[profileId] ?? const {},
      dialerTargets: dialerTargets[profileId] ?? const {},
      overrides:
          ref.read(profilesProvider).getProfile(profileId)?.overrides ??
          const ProfileOverrides(),
    );
  }

  Future<void> updateProfiles() async {
    for (final id in [
      for (final profile in ref.read(profilesProvider)) profile.id,
    ]) {
      final profile = ref.read(profilesProvider).getProfile(id);
      if (profile == null || profile.type != ProfileType.url) continue;
      await updateProfile(profile, showLoading: true);
    }
  }

  Future<void> updateProfile(
    Profile profile, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref.read(updatingKeysProvider.notifier).start(profile.updatingKey)
        : null;
    try {
      final managed = ref
          .read(profilesProvider)
          .where((item) => managedIspSourceId(item.url) == profile.id)
          .firstOrNull;
      if (system.isMacOS && !ref.read(safeModeProvider) && managed != null) {
        await _updateManagedSource(profile, managed);
        return;
      }
      ref.read(profilesProvider.notifier).put(profile);
      final updated = await profile.update(
        validate: (path, key) => _core.validateProfile(path, key),
      );
      // The download can take minutes; edits and deletes made meanwhile win.
      final latest = ref.read(profilesProvider).getProfile(profile.id);
      if (latest == null) {
        await clearEffect(profile.id);
        return;
      }
      final newProfile = latest.copyWith(
        label: latest.label.takeFirstValid([updated.label]),
        subscriptionInfo: updated.subscriptionInfo,
        lastUpdateDate: updated.lastUpdateDate,
      );
      ref.read(profilesProvider.notifier).put(newProfile);
      if (profile.id == ref.read(currentProfileIdProvider)) {
        ref
            .read(setupActionProvider.notifier)
            .applyProfileDebounce(silence: true);
      } else {
        final label = ref
            .read(profilesProvider.notifier)
            .labeled(newProfile)
            .realLabel;
        unawaited(
          ref.read(clashProvidersActionProvider.notifier).applyIfReferenced(
            ProviderKind.proxy,
            {label},
            force: true,
          ),
        );
      }
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(profile.updatingKey, operation);
      }
    }
  }

  Future<void> addProfileFormFile() async {
    final platformFile = await globalState.safeRun(picker.pickerFile);
    if (platformFile == null) return;
    final bytes = await platformFile.readBytes();
    globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    ref.read(currentPageLabelProvider.notifier).toProfiles();
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () => _withAgeSecretKey(
        Profile.normal(label: platformFile.name),
        (profile) => profile.saveFile(
          bytes,
          validate: (path, key) => _core.validateProfile(path, key),
        ),
      ),
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
    }
  }

  int addCustomProfile(String label) {
    final profile = Profile.custom(label: label);
    putProfile(profile);
    return profile.id;
  }

  void touchProfile(int id) {
    final profile = ref.read(profilesProvider).getProfile(id);
    if (profile == null) return;
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(lastUpdateDate: DateTime.now()));
  }

  Future<CustomProfileImport> readCustomImport(
    int profileId,
    Uint8List bytes,
  ) async {
    final profiles = ref.read(profilesProvider);
    final (ruleProviders, proxies, groupNames) = await (
      database.clashProvidersDao.query().get(),
      database.customProxiesDao.query().get(),
      database.proxyGroupsDao.names(except: profileId).get(),
    ).wait;
    final CustomImportApp app = (
      profileLabels: {
        for (final profile in profiles) ...[profile.label, profile.realLabel],
      },
      profileSources: {
        for (final profile in profiles)
          if (profile.type == ProfileType.url)
            (url: profile.url, ageSecretKey: profile.ageSecretKey):
                profile.realLabel,
      },
      ruleProviderLabels: {
        for (final provider in ruleProviders) provider.label,
      },
      ruleProviderSources: {
        for (final provider in ruleProviders)
          if (provider.isRemote)
            (url: provider.url, ageSecretKey: ''): provider.label,
      },
      proxies: [for (final proxy in proxies) proxy.definition],
      groupNames: groupNames.toSet(),
    );
    try {
      return await compute(readCustomProfileImport, (bytes: bytes, app: app));
    } on CustomImportException catch (error) {
      final appLocalizations = currentAppLocalizations;
      throw MessageException(switch (error.issue) {
        CustomImportIssue.unreadable => appLocalizations.importConfigInvalid,
        CustomImportIssue.ruleType => appLocalizations.failedItem(
          error.item,
          appLocalizations.ruleTextInvalid,
        ),
        CustomImportIssue.entry => appLocalizations.failedItem(
          error.item,
          error.detail,
        ),
      });
    }
  }

  /// [config] replaces what [profileId] holds. The providers it adds are saved
  /// before the groups and rules naming them, and loaded afterwards; the
  /// future completes once they have loaded.
  Future<void> importCustomProfile(int profileId, CustomProfileImport config) {
    final profiles = ref.read(profilesProvider.notifier);
    final clashProviders = ref.read(clashProvidersProvider.notifier);
    final loads = <({String label, Future<void> Function() load})>[];
    for (final (:label, :url, :ageSecretKey, :content)
        in config.proxyProviders) {
      final profile = Profile.normal(
        label: label,
        url: url,
      ).copyWith(ageSecretKey: ageSecretKey);
      profiles.put(profile);
      loads.add((
        label: label,
        load: url.isNotEmpty
            ? () => updateProfile(profile, showLoading: true)
            : () async => profiles.put(
                await profile.saveFile(
                  utf8.encode(content),
                  validate: (path, key) => _core.validateProfile(path, key),
                ),
              ),
      ));
    }
    for (final (:label, :url, ageSecretKey: _, :content)
        in config.ruleProviders) {
      final provider = ClashProvider.create(label: label, url: url);
      clashProviders.put(provider);
      loads.add((
        label: label,
        load: url.isNotEmpty
            ? () => ref
                  .read(resourcesActionProvider.notifier)
                  .updateRuleProvider(provider)
            : () => ref
                  .read(clashProvidersActionProvider.notifier)
                  .putProvider(provider, content: utf8.encode(content)),
      ));
    }
    final customProxies = ref.read(customProxiesProvider.notifier);
    customProxies.putAll([
      for (final definition in config.proxies)
        CustomProxy.fromDefinition(definition),
    ]);
    final proxyIds = {
      for (final proxy in customProxies.value) proxy.name: proxy.id,
    };
    ref.read(proxyGroupsProvider(profileId).notifier).setAll([
      for (final group in config.proxyGroups) group.copyWith(id: snowflake.id),
    ]);
    ref.read(profileRulesProvider(profileId).notifier).setAll([
      for (final rule in config.rules) rule.copyWith(id: snowflake.id),
    ]);
    ref.read(proxyDialersProvider(profileId).notifier).setAll({
      for (final MapEntry(:key, :value) in config.dialers.entries)
        ?proxyIds[key]: value,
    });
    profiles.updateProfile(
      profileId,
      (profile) => profile.copyWith(overrides: config.overrides),
    );
    return globalState.batchRun(
      loads,
      (item) => item.load(),
      label: (item) => item.label,
      concurrency: maxConcurrentImports,
      tag: null,
    );
  }

  void _showProfiles() {
    if (globalState.navigatorKey.currentState?.canPop() ?? false) {
      globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    ref.read(currentPageLabelProvider.notifier).value = PageLabel.profiles;
  }

  Future<void> addProfileFromLink(
    String link, {
    String? label,
    String ageSecretKey = '',
  }) async {
    _showProfiles();
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () => link.isShareLink
          ? _fromShareLinks(Profile.normal(label: label), [link])
          : _withAgeSecretKey(
              Profile.normal(
                label: label,
                url: link,
              ).copyWith(ageSecretKey: ageSecretKey),
              _download,
            ),
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
    }
  }

  /// Ids are taken up front so the list keeps the order of [links]; the share
  /// links among them make up one profile, in the place of the first.
  Future<void> addProfilesFromLinks(List<String> links) async {
    _showProfiles();
    final shareLinks = [
      for (final link in links)
        if (link.isShareLink) link,
    ];
    await globalState.batchRun(
      [
        for (final link in links)
          if (!link.isShareLink)
            (profile: Profile.normal(url: link), shareLinks: const <String>[])
          else if (link == shareLinks.first)
            (profile: Profile.normal(), shareLinks: shareLinks),
      ],
      (item) async => putProfile(
        await (item.shareLinks.isEmpty
            ? _download(item.profile)
            : _fromShareLinks(item.profile, item.shareLinks)),
      ),
      label: (item) => item.shareLinks.firstOrNull ?? item.profile.url,
      concurrency: maxConcurrentImports,
      tag: LoadingTag.profiles,
    );
  }

  Future<Profile> _download(Profile profile) {
    return profile.update(
      validate: (path, key) => _core.validateProfile(path, key),
    );
  }

  Future<Profile> _withAgeSecretKey(
    Profile profile,
    Future<Profile> Function(Profile profile) save,
  ) async {
    try {
      return await save(profile);
    } on AgeSecretKeyRequiredException {
      final key = (await dialogs.showAgeSecretKeyInput())?.trim();
      if (key == null || key.isEmpty) {
        rethrow;
      }
      return save(profile.copyWith(ageSecretKey: key));
    }
  }

  Future<Profile> _fromShareLinks(Profile profile, List<String> links) async {
    final appLocalizations = currentAppLocalizations;
    final decoded = await _core.decodeShareLinks(links);
    final taken = {...reservedCustomProxyNames};
    final proxies = <Map<String, dynamic>>[];
    for (final (index, definitions) in decoded.indexed) {
      if (definitions.isEmpty) {
        throw MessageException(
          links.length == 1
              ? appLocalizations.shareLinksInvalid
              : appLocalizations.shareLinkUnreadable(links[index]),
        );
      }
      for (final definition in definitions) {
        final name = freeProxyName(linkProxyName(definition), taken);
        proxies.add({...definition, 'name': name});
      }
    }
    final first = proxies.first['name'] as String;
    final label = proxies.length == 1
        ? first
        : appLocalizations.proxiesProfileLabel(first, proxies.length);
    final config = await encodeYamlTask({'proxies': proxies});
    return profile
        .copyWith(label: profile.label.takeFirstValid([label]))
        .saveFile(
          utf8.encode(config),
          validate: (path, _) => _core.validateConfig(path),
        );
  }

  Future<void> addProfileFormQrCode() async {
    final url = await globalState.safeRun(picker.pickerConfigQRCode);
    if (url == null) return;
    unawaited(addProfileFromLink(url));
  }

  Future<void> clearEffect(int profileId) async {
    final profilePath = await appPath.getProfilePath(profileId.toString());
    final profileFile = File(profilePath);
    final isExists = await profileFile.exists();
    if (isExists) {
      await profileFile.safeDelete(recursive: true);
    }
    try {
      await _core.clearEffect(profileId);
    } catch (error) {
      commonPrint.log(
        'clearEffect($profileId) failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
    }
  }
}

Map<String, List<String>> _managedIspAddresses(
  Map<String, dynamic> storage,
  String digest,
) {
  final snapshot = [
    storage['snapshot'],
    storage['previous'],
  ].whereType<Map>().where((item) => item['digest'] == digest).firstOrNull;
  final values = snapshot?['addresses'];
  if (values is! Map) return {};
  return {
    for (final MapEntry(:key, :value) in values.entries)
      if (key is String && value is List)
        key: value.whereType<String>().toList(),
  };
}
