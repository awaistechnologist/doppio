import Foundation

// Generated entry point: runs every suite.

let started = Date()
runSuite("CompatEngineTests", [
    TestCase(name: "bundledDatabaseLoads") { try CompatEngineTests().bundledDatabaseLoads() },
    TestCase(name: "ruleIDsAreUnique") { try CompatEngineTests().ruleIDsAreUnique() },
    TestCase(name: "exactBundleIDBeatsFrameworkSniffing") { try CompatEngineTests().exactBundleIDBeatsFrameworkSniffing() },
    TestCase(name: "longerPrefixWins") { try CompatEngineTests().longerPrefixWins() },
    TestCase(name: "prefixMatchesOnComponentBoundary") { try CompatEngineTests().prefixMatchesOnComponentBoundary() },
    TestCase(name: "frameworkSniffingCatchesUnknownElectronApps") { try CompatEngineTests().frameworkSniffingCatchesUnknownElectronApps() },
    TestCase(name: "sandboxedAppsGetDirectMode") { try CompatEngineTests().sandboxedAppsGetDirectMode() },
    TestCase(name: "unknownAppFallsBack") { try CompatEngineTests().unknownAppFallsBack() },
    TestCase(name: "chromiumRulesUseCloneMode") { try CompatEngineTests().chromiumRulesUseCloneMode() },
    TestCase(name: "isolatingRulesCarryTheirMechanism") { try CompatEngineTests().isolatingRulesCarryTheirMechanism() },
])
runSuite("IconFactoryTests", [
    TestCase(name: "iconSizesCoverStandardSet") { try IconFactoryTests().iconSizesCoverStandardSet() },
    TestCase(name: "hexColourRoundTrip") { try IconFactoryTests().hexColourRoundTrip() },
    TestCase(name: "badgeIsClampedToThreeCharacters") { try IconFactoryTests().badgeIsClampedToThreeCharacters() },
])
runSuite("LaunchPlanTests", [
    TestCase(name: "launchPlanKeys") { try LaunchPlanTests().launchPlanKeys() },
])
runSuite("PathSafetyTests", [
    TestCase(name: "writablePathsAreConfined") { try PathSafetyTests().writablePathsAreConfined() },
    TestCase(name: "configFileAvoidsResourcesDirectory") { try PathSafetyTests().configFileAvoidsResourcesDirectory() },
])
runSuite("PrivacyTests", [
    TestCase(name: "noNetworkingAPIs") { try PrivacyTests().noNetworkingAPIs() },
    TestCase(name: "noPersistentBackgroundMechanisms") { try PrivacyTests().noPersistentBackgroundMechanisms() },
    TestCase(name: "noWritesToTargetApplications") { try PrivacyTests().noWritesToTargetApplications() },
    TestCase(name: "noPrivateAPIs") { try PrivacyTests().noPrivateAPIs() },
    TestCase(name: "ephemeralEraseIsFenced") { try PrivacyTests().ephemeralEraseIsFenced() },
])
runSuite("ShotModelTests", [
    TestCase(name: "wrapperBundleIDIsUniqueAndNamespaced") { try ShotModelTests().wrapperBundleIDIsUniqueAndNamespaced() },
    TestCase(name: "wrapperIDNeverCollidesWithTarget") { try ShotModelTests().wrapperIDNeverCollidesWithTarget() },
    TestCase(name: "shotRoundTripsThroughJSON") { try ShotModelTests().shotRoundTripsThroughJSON() },
    TestCase(name: "launchModeIdentitySemantics") { try ShotModelTests().launchModeIdentitySemantics() },
])
runSuite("SubstitutionTests", [
    TestCase(name: "dataDirSubstitution") { try SubstitutionTests().dataDirSubstitution() },
    TestCase(name: "substitutionKeepsSpaces") { try SubstitutionTests().substitutionKeepsSpaces() },
])

runSuite("LaunchModeSafetyTests", [
    TestCase(name: "electronRulesUseCloneMode") { try LaunchModeSafetyTests().electronRulesUseCloneMode() },
    TestCase(name: "noShippedRuleDefaultsToLink") { try LaunchModeSafetyTests().noShippedRuleDefaultsToLink() },
    TestCase(name: "guardUpgradesElectronLinkShots") { try LaunchModeSafetyTests().guardUpgradesElectronLinkShots() },
    TestCase(name: "guardUpgradesChromiumLinkShots") { try LaunchModeSafetyTests().guardUpgradesChromiumLinkShots() },
    TestCase(name: "guardLeavesSimpleAppsAlone") { try LaunchModeSafetyTests().guardLeavesSimpleAppsAlone() },
    TestCase(name: "guardNeverRewritesDirect") { try LaunchModeSafetyTests().guardNeverRewritesDirect() },
])

runSuite("WrapperSafetyTests", [
    TestCase(name: "acceptsPathsInsideTheWrapper") { try WrapperSafetyTests().acceptsPathsInsideTheWrapper() },
    TestCase(name: "rejectsWritesThatEscapeThroughASymlink") { try WrapperSafetyTests().rejectsWritesThatEscapeThroughASymlink() },
    TestCase(name: "linkModeMirrorsResourcesInsteadOfSymlinkingIt") { try WrapperSafetyTests().linkModeMirrorsResourcesInsteadOfSymlinkingIt() },
])

runSuite("PathGuardTests", [
    TestCase(name: "shotNameCannotEscapeTheShotsDirectory") { try PathGuardTests().shotNameCannotEscapeTheShotsDirectory() },
    TestCase(name: "unsafeNamesAreRejected") { try PathGuardTests().unsafeNamesAreRejected() },
    TestCase(name: "ordinaryNamesAreAccepted") { try PathGuardTests().ordinaryNamesAreAccepted() },
    TestCase(name: "fileSafeNameNeutralisesTraversal") { try PathGuardTests().fileSafeNameNeutralisesTraversal() },
    TestCase(name: "traversalOutOfTheDataRootIsRefused") { try PathGuardTests().traversalOutOfTheDataRootIsRefused() },
    TestCase(name: "siblingDirectoryIsRefused") { try PathGuardTests().siblingDirectoryIsRefused() },
    TestCase(name: "theRootItselfIsRefused") { try PathGuardTests().theRootItselfIsRefused() },
    TestCase(name: "genuineDataDirectoriesAreAccepted") { try PathGuardTests().genuineDataDirectoriesAreAccepted() },
    TestCase(name: "userChosenDirectoryOutsideTheRootIsRefused") { try PathGuardTests().userChosenDirectoryOutsideTheRootIsRefused() },
    TestCase(name: "symlinkOutOfTheRootIsRefused") { try PathGuardTests().symlinkOutOfTheRootIsRefused() },
])

runSuite("SigningPolicyTests", [
    TestCase(name: "profileBoundEntitlementsAreFiltered") { try SigningPolicyTests().profileBoundEntitlementsAreFiltered() },
    TestCase(name: "hardenedRuntimeEntitlementsSurvive") { try SigningPolicyTests().hardenedRuntimeEntitlementsSurvive() },
    TestCase(name: "signingSetsFlagsExplicitly") { try SigningPolicyTests().signingSetsFlagsExplicitly() },
    TestCase(name: "targetBinaryKeepsItsName") { try SigningPolicyTests().targetBinaryKeepsItsName() },
])

runSuite("BehaviourTests", [
    TestCase(name: "directModeRunStateIsNotTheOriginalApp") { try BehaviourTests().directModeRunStateIsNotTheOriginalApp() },
    TestCase(name: "libraryWritesAreCoordinatedAndAtomic") { try BehaviourTests().libraryWritesAreCoordinatedAndAtomic() },
    TestCase(name: "testedUnsupportedFamiliesStayMarkedUnsupported") { try BehaviourTests().testedUnsupportedFamiliesStayMarkedUnsupported() },
    TestCase(name: "verifiedRulesAreTheOnesActuallyTested") { try BehaviourTests().verifiedRulesAreTheOnesActuallyTested() },
    TestCase(name: "verifierChecksTheShotStaysRunning") { try BehaviourTests().verifierChecksTheShotStaysRunning() },
])

runSuite("VerifierAndCLITests", [
    TestCase(name: "directModeIsNotDetectedByWrapperPath") { try VerifierAndCLITests().directModeIsNotDetectedByWrapperPath() },
    TestCase(name: "directModeWithoutIsolationIsIndistinguishable") { try VerifierAndCLITests().directModeWithoutIsolationIsIndistinguishable() },
    TestCase(name: "wrapperModesAreDetectedByPath") { try VerifierAndCLITests().wrapperModesAreDetectedByPath() },
    TestCase(name: "crashReportsAreAttributedToTheShot") { try VerifierAndCLITests().crashReportsAreAttributedToTheShot() },
    TestCase(name: "booleanFlagsDoNotSwallowTheNextArgument") { try VerifierAndCLITests().booleanFlagsDoNotSwallowTheNextArgument() },
    TestCase(name: "bothCopiesOfTheRulesDatabaseAreIdentical") { try VerifierAndCLITests().bothCopiesOfTheRulesDatabaseAreIdentical() },
    TestCase(name: "homeStrategyRulesJustifyThemselves") { try VerifierAndCLITests().homeStrategyRulesJustifyThemselves() },
])

runSuite("RoundThreeTests", [
    TestCase(name: "popupCloseHasASinglePruningPath") { try RoundThreeTests().popupCloseHasASinglePruningPath() },
    TestCase(name: "crashAttributionDoesNotOverMatchClones") { try RoundThreeTests().crashAttributionDoesNotOverMatchClones() },
    TestCase(name: "webDataIsCountedRecursively") { try RoundThreeTests().webDataIsCountedRecursively() },
    TestCase(name: "webDataDeletionCoversBothLayouts") { try RoundThreeTests().webDataDeletionCoversBothLayouts() },
    TestCase(name: "darkAppearanceIsNotOffered") { try RoundThreeTests().darkAppearanceIsNotOffered() },
    TestCase(name: "cliLaunchPathsReportFailure") { try RoundThreeTests().cliLaunchPathsReportFailure() },
])

runSuite("UninstallerTests", [
    TestCase(name: "removalIsFencedPerItemKind") { try UninstallerTests().removalIsFencedPerItemKind() },
    TestCase(name: "traversalCannotEscapeTheUninstaller") { try UninstallerTests().traversalCannotEscapeTheUninstaller() },
    TestCase(name: "onlyDoppiosOwnCommandLineToolIsRemoved") { try UninstallerTests().onlyDoppiosOwnCommandLineToolIsRemoved() },
    TestCase(name: "keepDataExcludesEveryDataItem") { try UninstallerTests().keepDataExcludesEveryDataItem() },
    TestCase(name: "keepAppExcludesTheApplication") { try UninstallerTests().keepAppExcludesTheApplication() },
])

let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
print("")
if Check.failures.isEmpty {
    print("All checks passed — \(Check.passed) assertions in \(elapsed).")
    exit(0)
} else {
    print("\(Check.failures.count) failure(s), \(Check.passed) passed:")
    for failure in Check.failures { print("  - \(failure)") }
    exit(1)
}
