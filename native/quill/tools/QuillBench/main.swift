import Foundation

// quill-bench: measures rewrite quality per profile and model (docs/initiatives/quill/BENCH.md).
// Run it through Scripts/bench.sh, which builds it, signs it and passes --data.

exit(await QuillBenchCLI.main(Array(CommandLine.arguments.dropFirst())))
