/// 应用内提供下载的第三方字体及其许可声明。
///
/// 字体不在 pub 依赖里，不会进入 Flutter 的 NOTICES，必须在应用内单独声明：
/// - MiSans 的许可要求嵌入使用时注明「使用了 MiSans 字体」。
/// - 霞鹜文楷以 SIL Open Font License 1.1 发布，需随附版权与许可全文。
class FontLicense {
  const FontLicense({
    required this.id,
    required this.name,
    required this.licenseName,
    required this.text,
  });

  /// 路由参数，避免字体名中的空格与斜杠进入 URL。
  final String id;
  final String name;

  /// 许可名称，显示在列表副标题。
  final String licenseName;
  final String text;
}

const fontLicenses = <FontLicense>[
  FontLicense(
    id: 'misans',
    name: 'MiSans',
    licenseName: 'MiSans 字体知识产权许可协议',
    text: '''本应用使用 MiSans 字体。

MiSans 字体版权归小米科技有限责任公司所有。依据《MiSans 字体知识产权许可协议》，MiSans 可免费用于商业与非商业用途，也可嵌入软件使用；嵌入使用时须注明使用了 MiSans 字体。不得单独修改字体外观，不得转售字体文件。

官方说明与许可协议：https://hyperos.mi.com/font/zh/faq/
''',
  ),
  FontLicense(
    id: 'lxgw-wenkai',
    name: '霞鹜文楷',
    licenseName: 'SIL Open Font License 1.1',
    text:
        '''Copyright 2021-2026 LXGW (https://github.com/lxgw/LxgwWenKai), with Reserved Font Name '霞鹜', '霞鶩', '落霞孤鹜', '落霞孤鶩' and 'LXGW'. [ADDITIONAL PERMISSION] The Reserved Font Names '霞鹜', '霞鶩', '落霞孤鹜', '落霞孤鶩' and 'LXGW' may continue to be used in Modified Versions recompiled from the Original Version, without modifications to the font source code; or in Modified Versions subsetted or converted to other formats (e.g., WOFF/WOFF2) solely for web font delivery, provided such Modified Versions are not made available as installable desktop fonts (e.g., on mainstream platforms like Google Fonts, or third-party non-commercial platforms recognized by the author @lxgw; other web font platforms please contact the author @lxgw for confirmation).
Copyright 2020 The Klee Project Authors (https://github.com/fontworks-fonts/Klee)

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
https://openfontlicense.org


-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded, 
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.''',
  ),
];

FontLicense? findFontLicense(String id) {
  for (final font in fontLicenses) {
    if (font.id == id) return font;
  }
  return null;
}
