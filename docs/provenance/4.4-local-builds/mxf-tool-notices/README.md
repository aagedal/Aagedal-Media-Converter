# MXF tool attribution review — 2026-09-12

The bundled BMX tools identify themselves as `bmx v1.6.2` with source marker
`v1.6-2-g278a9027`. Notices were recovered from that exact commit of
https://github.com/bbc/bmx . Its embedded libMXF and libMXF++ COPYING files are
identical to BMX's BBC BSD license. Their inclusion is now named explicitly.
The actual binary symbol tables additionally identify Fraunhofer JPEG XS
implementation/metadata, Colin Plumb's MD5, and Steve Reid's SHA-1. Their
original source-file notices are now packaged in `Licenses/bmx-LICENSE.txt`.

`asdcp-wrap -V` identifies asdcplib 2.13.2. Notices were recovered from
`rel_2_13_2` of https://github.com/cinecert/asdcplib . Its original COPYING
and asdcp-wrap source notice replace the previous generic reworded BSD text.
The binary contains Kumu AES, SHA-1, libtai and an ACES header constant; their
source notices are included. This preserves the tiny-AES public-domain grant,
Steve Reid attribution, D. J. Bernstein's libtai public-domain declaration,
and the ACES authors. The release tag is version-matched source evidence,
not a claim that unretained local build modifications have been reproduced.

`inventory.json` records upstream commits, binary SHA-256 values, specific
supporting symbols, dynamic-library listings, complete original source-file
hashes, and extracted notice hashes. Each sibling snapshot is verbatim notice
text from its named upstream path; COPYING files are complete. Code bodies are
not copied into the notice set.

BMX uses macOS system libexpat and libcurl (absolute `/usr/lib/` install names).
Those are not bundled static copies. asdcp-wrap links only macOS libc++ and
libSystem, and its AES/SHA symbols are Kumu's implementations; speculative
OpenSSL attribution was not substituted for the actual implementation.

Validation: all five executable identities inspected; selected static symbols
and dynamic library records captured; each packaged license section checked
byte-for-byte against its retained notice snapshot.
