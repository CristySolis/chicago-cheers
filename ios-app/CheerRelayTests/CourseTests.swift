import Testing
@testable import CheerRelay

/// The slots must match the ones the server hands out (backend tests build the
/// same 39), or a cheer claimed on the sender page would never play.
struct CourseTests {

    @Test func everyMileForTheFirstHalfThenEveryHalfMile() {
        let firstHalf = Array(1...13).map(Double.init)
        let secondHalf = stride(from: 13.5, through: 26, by: 0.5).map { $0 }

        #expect(Course.slots == firstHalf + secondHalf)
        #expect(Course.slots.count == 39)
    }

    @Test func slotsRunInCourseOrderAndStopBeforeTheFinish() {
        #expect(zip(Course.slots, Course.slots.dropFirst()).allSatisfy { $0 < $1 })
        #expect(Course.slots.first == 1)
        #expect(Course.slots.last == 26) // the finish, 26.2, is not a slot
    }

    @Test(arguments: [1.0, 13, 13.5, 20, 25.5, 26])
    func slotsAreRecognised(_ miles: Double) {
        #expect(Course.isSlot(miles))
    }

    @Test(arguments: [0.0, 0.5, 12.5, 13.25, 26.2, 27])
    func otherDistancesAreNot(_ miles: Double) {
        #expect(!Course.isSlot(miles))
    }

    @Test func labelsShowHalfMilesAsDecimals() {
        #expect(Course.label(20) == "Mile 20")
        #expect(Course.label(13.5) == "Mile 13.5")
    }

    @Test func aMileIsAStatuteMile() {
        #expect(Course.metresPerMile == 1609.344)
    }
}
