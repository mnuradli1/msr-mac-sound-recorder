# Third-Party Notices

MSR has no third-party runtime dependencies. DOCX export writes its ZIP container with a small built-in writer (`ZipArchiveWriter`, stored entries only); earlier versions used ZIPFoundation 0.9.20 (MIT License, Copyright © 2017-2025 Thomas Zoechling and contributors), which is no longer included.

MSR uses swift-testing 0.12.0 only in the test target. swift-testing is distributed under the Apache License 2.0 with Runtime Library Exception.
