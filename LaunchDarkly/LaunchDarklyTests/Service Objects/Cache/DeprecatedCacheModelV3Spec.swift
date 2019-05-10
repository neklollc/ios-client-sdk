//
//  DeprecatedCacheModelV3Spec.swift
//  LaunchDarklyTests
//
//  Created by Mark Pokorny on 4/2/19. +JMJ
//  Copyright © 2019 Catamorphic Co. All rights reserved.
//

import Foundation
import Quick
import Nimble
@testable import LaunchDarkly

final class DeprecatedCacheModelV3Spec: QuickSpec {

    struct Constants {
        static let offsetInterval: TimeInterval = 0.1
    }

    struct TestContext {
        var clientServiceFactoryMock = ClientServiceMockFactory()
        var keyedValueCacheMock: KeyedValueCachingMock
        var modelV3cache: DeprecatedCacheModelV3
        var users: [LDUser]
        var userEnvironmentsCollection: [UserKey: CacheableUserEnvironmentFlags]
        var uncachedUser: LDUser
        var mobileKeys: [MobileKey]
        var uncachedMobileKey: MobileKey
        var firstMobileKey: MobileKey {
            return mobileKeys.first!
        }
        var lastUpdatedDates: [UserKey: Date] {
            return userEnvironmentsCollection.compactMapValues { (cacheableUserFlags)  in
                return cacheableUserFlags.lastUpdated
            }
        }
        var sortedLastUpdatedDates: [(userKey: UserKey, lastUpdated: Date)] {
            return lastUpdatedDates.map { (userKey, lastUpdated) in
                return (userKey, lastUpdated)
            }.sorted { (tuple1, tuple2) in
                return tuple1.lastUpdated.isEarlierThan(tuple2.lastUpdated)
            }
        }
        var userKeys: [UserKey] {
            return users.map { (user) in
                return user.key
            }
        }

        init(userCount: Int = 0) {
            keyedValueCacheMock = clientServiceFactoryMock.makeKeyedValueCache() as! KeyedValueCachingMock
            modelV3cache = DeprecatedCacheModelV3(keyedValueCache: keyedValueCacheMock)

            (users, userEnvironmentsCollection, mobileKeys) = CacheableUserEnvironmentFlags.stubCollection(userCount: userCount)

            uncachedUser = LDUser.stub()
            uncachedMobileKey = UUID().uuidString

            keyedValueCacheMock.dictionaryReturnValue = modelV3Dictionary(for: users, and: userEnvironmentsCollection, storingMobileKey: mobileKeys.first)
        }

        func featureFlags(for userKey: UserKey) -> [LDFlagKey: FeatureFlag]? {
            guard !mobileKeys.isEmpty
            else {
                return nil
            }

            return userEnvironmentsCollection[userKey]?.environmentFlags[firstMobileKey]?.featureFlags.modelV3flagCollection
        }

        func modelV3Dictionary(for users: [LDUser], and userEnvironmentsCollection: [UserKey: CacheableUserEnvironmentFlags], storingMobileKey: MobileKey?) -> [UserKey: Any]? {
            guard let mobileKey = storingMobileKey, !users.isEmpty
            else {
                return nil
            }

            return Dictionary(uniqueKeysWithValues: users.map { (user) in
                let featureFlags = userEnvironmentsCollection[user.key]?.environmentFlags[mobileKey]?.featureFlags
                let lastUpdated = userEnvironmentsCollection[user.key]?.lastUpdated
                return (user.key, user.modelV3DictionaryValue(including: featureFlags!, using: lastUpdated))
            })
        }

        func expiredUserKeys(for expirationDate: Date) -> [UserKey] {
            return sortedLastUpdatedDates.compactMap { (tuple) in
                guard tuple.lastUpdated.isEarlierThan(expirationDate)
                else {
                    return nil
                }
                return tuple.userKey
            }
        }
    }

    override func spec() {
        initSpec()
        retrieveFlagsSpec()
        removeDataSpec()
    }

    private func initSpec() {
        var testContext: TestContext!
        describe("init") {
            context("with keyed value cache") {
                beforeEach {
                    testContext = TestContext()
                }
                it("creates a model version 3 cache with the keyed value cache") {
                    expect(testContext.modelV3cache.keyedValueCache) === testContext.keyedValueCacheMock
                }
            }
        }
    }

    private func retrieveFlagsSpec() {
        var testContext: TestContext!
        var cachedData: (featureFlags: [LDFlagKey: FeatureFlag]?, lastUpdated: Date?)!
        describe("retrieveFlags") {
            context("when no cached data exists") {
                beforeEach {
                    testContext = TestContext()

                    cachedData = testContext.modelV3cache.retrieveFlags(for: testContext.uncachedUser.key, and: testContext.uncachedMobileKey)
                }
                it("returns nil values") {
                    expect(cachedData.featureFlags).to(beNil())
                    expect(cachedData.lastUpdated).to(beNil())
                }
            }
            context("when cached data exists") {
                context("and a cached user is requested") {
                    beforeEach {
                        testContext = TestContext(userCount: UserEnvironmentFlagCache.Constants.maxCachedUsers)
                    }
                    it("retrieves the cached data") {
                        testContext.users.forEach { (user) in
                            let expectedFlags = testContext.featureFlags(for: user.key)
                            let expectedLastUpdated = testContext.userEnvironmentsCollection.lastUpdated(forKey: user.key)?.stringEquivalentDate
                            testContext.mobileKeys.forEach { (mobileKey) in
                                cachedData = testContext.modelV3cache.retrieveFlags(for: user.key, and: mobileKey)
                                expect(cachedData.featureFlags) == expectedFlags
                                expect(cachedData.lastUpdated) == expectedLastUpdated
                            }
                        }
                    }
                }
                context("and an uncached user is requested") {
                    beforeEach {
                        testContext = TestContext(userCount: UserEnvironmentFlagCache.Constants.maxCachedUsers)

                        cachedData = testContext.modelV3cache.retrieveFlags(for: testContext.uncachedUser.key, and: testContext.uncachedMobileKey)
                    }
                    it("returns nil values") {
                        expect(cachedData.featureFlags).to(beNil())
                        expect(cachedData.lastUpdated).to(beNil())
                    }
                }
            }
        }
    }

    private func removeDataSpec() {
        var testContext: TestContext!
        var expirationDate: Date!
        describe("removeData") {
            context("no modelV3 cached data expired") {
                beforeEach {
                    testContext = TestContext(userCount: UserEnvironmentFlagCache.Constants.maxCachedUsers)
                    let oldestLastUpdatedDate = testContext.sortedLastUpdatedDates.first!
                    expirationDate = oldestLastUpdatedDate.lastUpdated.addingTimeInterval(-Constants.offsetInterval)

                    testContext.modelV3cache.removeData(olderThan: expirationDate)
                }
                it("does not remove any modelV3 cached data") {
                    expect(testContext.keyedValueCacheMock.setCallCount) == 0
                }
            }
            context("some modelV3 cached data expired") {
                beforeEach {
                    testContext = TestContext(userCount: UserEnvironmentFlagCache.Constants.maxCachedUsers)
                    let selectedLastUpdatedDate = testContext.sortedLastUpdatedDates[testContext.users.count / 2]
                    expirationDate = selectedLastUpdatedDate.lastUpdated.addingTimeInterval(-Constants.offsetInterval)

                    testContext.modelV3cache.removeData(olderThan: expirationDate)
                }
                it("removes expired modelV3 cached data") {
                    expect(testContext.keyedValueCacheMock.setCallCount) == 1
                    expect(testContext.keyedValueCacheMock.setReceivedArguments?.forKey) == CacheConverter.CacheKeys.ldUserModelDictionary
                    let recachedData = testContext.keyedValueCacheMock.setReceivedArguments?.value as? [String: Any]
                    let expiredUserKeys = testContext.expiredUserKeys(for: expirationDate)
                    testContext.userKeys.forEach { (userKey) in
                        expect(recachedData?.keys.contains(userKey)) == !expiredUserKeys.contains(userKey)
                    }
                }
            }
            context("all modelV3 cached data expired") {
                beforeEach {
                    testContext = TestContext(userCount: UserEnvironmentFlagCache.Constants.maxCachedUsers)
                    let newestLastUpdatedDate = testContext.sortedLastUpdatedDates.last!
                    expirationDate = newestLastUpdatedDate.lastUpdated.addingTimeInterval(Constants.offsetInterval)

                    testContext.modelV3cache.removeData(olderThan: expirationDate)
                }
                it("removes all modelV3 cached data") {
                    expect(testContext.keyedValueCacheMock.removeObjectCallCount) == 1
                    expect(testContext.keyedValueCacheMock.removeObjectReceivedForKey) == CacheConverter.CacheKeys.ldUserModelDictionary
                }
            }
            context("no modelV3 cached data exists") {
                beforeEach {
                    testContext = TestContext(userCount: UserEnvironmentFlagCache.Constants.maxCachedUsers)
                    let newestLastUpdatedDate = testContext.sortedLastUpdatedDates.last!
                    expirationDate = newestLastUpdatedDate.lastUpdated.addingTimeInterval(Constants.offsetInterval)
                    testContext.keyedValueCacheMock.dictionaryReturnValue = nil     //mock simulates no modelV3 cached data

                    testContext.modelV3cache.removeData(olderThan: expirationDate)
                }
                it("makes no cached data changes") {
                    expect(testContext.keyedValueCacheMock.setCallCount) == 0
                }
            }
        }
    }

}

// MARK: Expected value from conversion

extension Dictionary where Key == LDFlagKey, Value == FeatureFlag {
    var modelV3flagCollection: [LDFlagKey: FeatureFlag] {
        return compactMapValues { (originalFeatureFlag) in
            guard originalFeatureFlag.value != nil
            else {
                return nil
            }
            return originalFeatureFlag.modelV3FeatureFlag
        }
    }
}

extension FeatureFlag {
    var modelV3FeatureFlag: FeatureFlag {
        return FeatureFlag(flagKey: flagKey, value: value, variation: nil, version: version, flagVersion: nil, eventTrackingContext: nil)
    }
}

// MARK: Dictionary value to cache

extension LDUser {
    func modelV3DictionaryValue(including featureFlags: [LDFlagKey: FeatureFlag], using lastUpdated: Date?) -> [String: Any] {
        var userDictionary = dictionaryValueWithAllAttributes(includeFlagConfig: false)
        userDictionary.setLastUpdated(lastUpdated)
        userDictionary[LDUser.CodingKeys.config.rawValue] = featureFlags.compactMapValues { (featureFlag) in
            return featureFlag.modelV3dictionaryValue
        }

        return userDictionary
    }
}

extension FeatureFlag {
/*
     [“version”: <modelVersion>,
      “value”: <value>]
*/
    var modelV3dictionaryValue: [String: Any]? {
        guard value != nil
        else {
            return nil
        }
        var flagDictionary = dictionaryValue
        flagDictionary.removeValue(forKey: FeatureFlag.CodingKeys.flagKey.rawValue)
        flagDictionary.removeValue(forKey: FeatureFlag.CodingKeys.variation.rawValue)
        flagDictionary.removeValue(forKey: FeatureFlag.CodingKeys.flagVersion.rawValue)
        flagDictionary.removeValue(forKey: EventTrackingContext.CodingKeys.trackEvents.rawValue)
        flagDictionary.removeValue(forKey: EventTrackingContext.CodingKeys.debugEventsUntilDate.rawValue)
        return flagDictionary
    }
}
