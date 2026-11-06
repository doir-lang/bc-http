module runner;

private alias modules = imported!"std.meta".AliasSeq!(
	"bc.json",
	"bc.jsonrpc",
	"bc.http.message",
	"bc.http",
);

private int runEveryTest() {
	cast(void) imported!"fp.testing".runTests!modules("bc-fetch");
	return 0;
}

version(BchCoverage) {
	shared static this() {
		import core.runtime : Runtime, UnitTestResult;
		Runtime.extendedModuleUnitTester = () => UnitTestResult(0, 0, true, false);
	}

	int main() { return runEveryTest(); }
} else
	extern(C) int main() { return runEveryTest(); }
