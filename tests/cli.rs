//! CLI transcripts (trycmd): the usage screen, the usage errors and the
//! `--<flag> is only valid with --run.` lines, byte for byte.

#[test]
fn cli_transcripts() {
    trycmd::TestCases::new().case("tests/cmd/*.toml");
}
