import LoomKit
import XCTest

final class ModelCatalogueTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func testTheDaemonsListSaysWhichModelsReadImages() throws {
        let body = try json(#"{"models":[{"key":"opus","model_id":"claude-opus-5","dialect":"anthropic","vision":true,"roles":["main"]},{"key":"flash","vision":false,"roles":[]}],"profiles":["codex","review"]}"#)
        let catalogue = try XCTUnwrap(ModelCatalogue(reply: body))
        XCTAssertEqual(catalogue.models.map(\.key), ["opus", "flash"])
        XCTAssertEqual(catalogue.models.first?.modelID, "claude-opus-5")
        XCTAssertEqual(catalogue.models.first?.roles, ["main"])
        XCTAssertEqual(catalogue.imageReaders.map(\.key), ["opus"])
        XCTAssertEqual(catalogue.profiles, ["codex", "review"])
    }

    func testAMalformedListGivesNothingRatherThanHalf() throws {
        XCTAssertNil(ModelCatalogue(reply: try json(#"{"models":[{"key":"opus"}],"profiles":[]}"#)), "a row without its vision flag")
        XCTAssertNil(ModelCatalogue(reply: try json(#"{"models":[{"key":"","vision":true}],"profiles":[]}"#)), "an empty key")
        XCTAssertNil(ModelCatalogue(reply: try json(#"{"models":[],"profiles":[3]}"#)), "a profile that is not a name")
        XCTAssertNil(ModelCatalogue(reply: try json(#"{"profiles":[]}"#)), "no models at all")
    }

    func testAFileNamesTheKeysButSaysNothingAboutImages() {
        let catalogue = ModelCatalogue(file: ConfigurationChoices.parse("[models.opus]\nvision = true\n[models.flash]\n[profiles.review.roles]\n"))
        XCTAssertEqual(catalogue.models.map(\.key), ["opus", "flash"])
        XCTAssertEqual(catalogue.profiles, ["review"])
        XCTAssertTrue(catalogue.imageReaders.isEmpty, "only the daemon judges which models read images")
    }
}
