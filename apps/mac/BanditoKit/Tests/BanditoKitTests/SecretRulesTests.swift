import Testing

@testable import BanditoKit

@Suite struct SecretRulesTests {
    @Test func acceptsEnvironmentStyleNames() {
        #expect(SecretRules.isValidName("OPENAI_API_KEY"))
        #expect(SecretRules.isValidName("_PRIVATE"))
        #expect(SecretRules.isValidName("DB2_URL"))
        #expect(SecretRules.isValidName(String(repeating: "A", count: 64)))
    }

    @Test func rejectsBadShapes() {
        #expect(!SecretRules.isValidName(""))
        #expect(!SecretRules.isValidName("1TOKEN"))
        #expect(!SecretRules.isValidName("lower_case"))
        #expect(!SecretRules.isValidName("HAS-DASH"))
        #expect(!SecretRules.isValidName("HAS SPACE"))
        #expect(!SecretRules.isValidName(String(repeating: "A", count: 65)))
    }

    @Test func rejectsNamesTheServerReserves() {
        for name in ["PATH", "HOME", "USER", "SHELL", "LD_PRELOAD", "LD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES", "BANDITO_HOME"] {
            #expect(!SecretRules.isValidName(name), "\(name) must be refused")
        }
    }

    @Test func valueMustBeNonEmptyWithoutNulAndAtMost65536Bytes() {
        #expect(!SecretRules.isValidValue(""))
        #expect(SecretRules.isValidValue("x"))
        #expect(!SecretRules.isValidValue("a\u{0}b"))
        #expect(SecretRules.isValidValue(String(repeating: "a", count: 65_536)))
        #expect(!SecretRules.isValidValue(String(repeating: "a", count: 65_537)))
    }
}
