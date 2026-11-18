import AppKit
import Foundation
@testable import SwitchBladeCore

enum CatalogReliabilityTests {
 static let all: [(String, @MainActor () async throws -> Void)] = [
  ("CatalogReliability/unverifiedRowHidesContentUntilConfirmed", unverifiedRowHidesContentUntilConfirmed),
  ("CatalogReliability/sharedRefreshDeadlineAndInvalidation", sharedRefreshDeadlineAndInvalidation),
  ("CatalogReliability/partialScanResumesAndRetainsSafely", partialScanResumesAndRetainsSafely)
 ]
 @MainActor static func sharedRefreshDeadlineAndInvalidation() async throws {
  let calls=LockedValue(0)
  let released=LockedValue(false)
  let cache=SCContentCache(refreshProvider: {
   calls.withValue{$0 += 1}
   // Ignore cancellation just like a wedged platform boundary may do.
   while !released.value { try? await Task.sleep(nanoseconds: 5_000_000) }
   return nil
  }, recordingPermission:{true})
  let first=Task{await cache.refreshIfAllowed()}
  while calls.value == 0 { await Task.yield() }
  await cache.invalidate(reason:"test epoch")
  let waiters=(0..<25).map{_ in Task{await cache.refreshIfAllowed()}}
  first.cancel()
  for t in waiters { await t.value }
  try expectEqual(calls.value,1,"invalidations/cancellation must not start extra physical requests")
  released.withValue{$0=true}
  for _ in 0..<100 where await cache.lastSuccessfulRefresh == nil { try? await Task.sleep(nanoseconds:1_000_000) }
  try expectNil(await cache.lastSuccessfulRefresh,"old epoch cannot commit freshness")
  await cache.refreshIfAllowed()
  try expectEqual(calls.value,2)
  try expect(await cache.lastSuccessfulRefresh != nil)
 }
 @MainActor static func unverifiedRowHidesContentUntilConfirmed() throws {
  let now = Date()
  let row = makeItem(id: 11, title: "Prior title", isMinimized: true)
  for unknown in [MinimizedWindowSnapshot(items: [], isComplete: true, unresolvedWindowProcessIDs: [row.pid]),
                  MinimizedWindowSnapshot(items: [], isComplete: false)] {
   var cache = MinimizedWindowCache()
   let confirmed = MinimizedWindowSnapshot(items: [row], isComplete: true)
   _ = cache.reconcile(confirmed, visibleItems: [], now: now, maxAge: 30)
   let retained = cache.reconcile(unknown, visibleItems: [], now: now.addingTimeInterval(1), maxAge: 30)
   try expectEqual(retained.map(\.id), [row.id])
   try expectEqual(retained.first?.displayTitle, row.appName)
   try expect(retained.first?.canCapturePreview == false && retained.first?.preview == nil)
   try expectEqual(cache.freshItems(now: now, maxAge: 30).first?.displayTitle, row.appName)
   let restored = cache.reconcile(confirmed, visibleItems: [], now: now.addingTimeInterval(2), maxAge: 30)
   try expectEqual(restored.first?.displayTitle, row.title)
   try expect(restored.first?.canCapturePreview == true)
  }
 }
 @MainActor static func partialScanResumesAndRetainsSafely() async throws {
  var next:Int?=nil
  func scan() -> MinimizedAXScanExecutionResult<Int> {
   MinimizedAXScanExecution.run(candidates:[1], maximumWindows:128, maximumElapsedSeconds:2, startedAt:0,
    now:{0},isCancelled:{false},startingWindowIndex:{_ in next ?? 0},onCandidateProgress:{_,n in next=n},
    windowsForCandidate:{_ in Array(0..<129)},itemForWindow:{_,_,n in n})
  }
  let a=scan(),b=scan()
  try expect(!a.isComplete && !b.isComplete)
  try expectEqual(Set(a.items+b.items).count,129,"partial owner must resume beyond window128")
  try expectEqual(a.incompleteCandidateIndices,[0])
  var cache=MinimizedWindowCache();let now=Date()
  let old=makeItem(id:7,pid:100,title:"Private",isMinimized:true)
  _=cache.reconcile(.init(items:[old],isComplete:true),visibleItems:[],now:now,maxAge:30)
  let fresh=makeItem(id:8,pid:100,isMinimized:true)
  let partial=cache.reconcile(.init(items:[fresh],isComplete:false,incompleteWindowProcessIDs:[100]),visibleItems:[],now:now,maxAge:30)
  try expectEqual(Set(partial.map(\.id)),[7,8])
  let retained=partial.first{$0.id == 7}!
  try expect(retained.isTitleRedacted && !retained.canCapturePreview && retained.preview == nil)
  let expired=cache.reconcile(.init(items:[],isComplete:false,incompleteWindowProcessIDs:[100]),visibleItems:[],now:now.addingTimeInterval(31),maxAge:30)
  try expect(expired.isEmpty,"partial traversal must not renew old confirmation age")
 }
}
