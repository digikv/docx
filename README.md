# docx

Create, read and fill `.docx` (Word) documents with a pure Harbour class. No Word, OLE/ActiveX or external DLLs are needed.
Everything is in one source file: `DOCXClass.prg`. It is the companion of the [xlsx](https://github.com/digikv/xlsx) class.

## Features

- Paragraphs with formatted text: fonts, sizes, bold, italic, underline, strikethrough, colors, background
- Paragraph styles: alignment (also justified), spacing, line spacing, indents, background, keep with next, page break before
- Title and headings 1-6 (Word's built-in styles, so the navigation pane and the table of contents work)
- Bulleted and numbered lists, nested up to 9 levels
- Tables: column widths, borders, shading, merged cells (horizontal and vertical), vertical alignment,
  header rows repeated on every page, number formats per column; a cell can hold several paragraphs, pictures or another table
- Pictures (PNG, JPG, GIF, BMP) in their own paragraph, inside a line of text or in a table cell
- Charts: column, bar, line, area, pie, doughnut; the data also in an embedded workbook (Word: Edit Data)
- Hyperlinks, page breaks, page number fields, table of contents
- Header and footer, with Excel-like codes `&P`, `&N`, `&D`, `&T`, `&F`; page numbering from any page,
  a cover page without header and footer
- PDF: `SavePDF()` through Word (when installed) or LibreOffice
- **Digital signature** of a PDF with a certificate (A1 / A3, `.pfx`): `PDF_Sign()` in `PDFSign.prg`, the
  signature visible at the row and column given
- Page setup: paper size, orientation, margins
- Text is written as UTF-8; text in another codepage (e.g. from a DBF) is converted automatically
- **Templates**: read a document made in Word, replace placeholders like `{{customer}}` (also when Word split them
  into several parts), repeat a table row for every item, insert new content at a marker, save under a new name
- **Reading**: paragraphs with their style names, tables as arrays, all text

## Building

Add `DOCXClass.prg` to your project and link the `hbmzip` contrib (Harbour 3.2):

```
hbmk2 myapp.prg DOCXClass.prg hbmzip.hbc
```

The `samples` folder has ready-made `.hbp` files; `build.bat` (Windows) or `./build.sh` (Linux)
builds all samples and passes hbmk2 options on (`build -comp=bcc`):

```
cd samples
build

rem or one by one:
hbmk2 docxwriter.hbp
hbmk2 docxtemplate.hbp
hbmk2 docxreader.hbp
hbmk2 docxchart.hbp
hbmk2 docxreport.hbp
hbmk2 docxsign.hbp
```

The class can be linked together with `XLSXClass.prg` in the same program.

## Quick start

```harbour
#include "hbclass.ch"
REQUEST HB_CODEPAGE_UTF8EX

PROCEDURE Main()
   LOCAL oDoc, nBold

   hb_cdpSelect( "UTF8EX" )

   oDoc := WordDocument():New( "hello.docx" )
   nBold := oDoc:NewFont( , , .T. )

   oDoc:Title( "Hello world" )
   oDoc:Heading( "Introduction", 1 )
   oDoc:Paragraph( "Plain text and " ):Text( "bold text", nBold ):Text( "." )
   oDoc:ListItem( "first item" )
   oDoc:ListItem( "second item" )

   IF ! oDoc:Save()
      ? oDoc:cError                      // e.g. the file is open in Word
   ENDIF

   RETURN
```

## Examples

### Text and fonts

`Paragraph( xText, nStyle )` adds a paragraph and returns it. More text with its own font is added with
`Text( xText, nFont )`; the methods of a paragraph return the paragraph, so they can be chained.
`Chr(10)` (or CRLF) starts a new line inside the paragraph, `Chr(9)` is a tab.
Numbers and dates are converted to text (`DToC()` for dates).

```harbour
// NewFont( cFont, nSize, lBold, lItalic, lUnderline, lStrike, cColor, cBackColor )
nBold   := oDoc:NewFont( , , .T. )
nItalic := oDoc:NewFont( , , , .T. )
nRed    := oDoc:NewFont( "Arial", 12, .T., , , , "C00000" )
nMark   := oDoc:NewFont( , , , , , , , "FFFF00" )          // yellow background

oP := oDoc:Paragraph( "Normal, " )
oP:Text( "bold", nBold ):Text( ", " ):Text( "italic", nItalic ):Text( ", " ):Text( "red", nRed )
oP:LineBreak()
oP:Text( "marked", nMark )

oDoc:Paragraph( "Line 1" + Chr( 10 ) + "Line 2" + Chr( 10 ) + "Name:" + Chr( 9 ) + "Petar" )
oDoc:Paragraph( "Web: " ):Link( "sokdoo.com", "https://sokdoo.com" )
```

A parameter left as `NIL` is inherited (from the paragraph style or the document). `.F.` switches an attribute off,
e.g. `NewFont( , , .F. )` is a heading without bold. Colors are RGB hex (`"FF0000"`);
ARGB colors of the xlsx class (`"FFFF0000"`) are accepted too.

### Paragraph styles

```harbour
// NewStyle( nFont, nAlign, nSpaceBefore, nSpaceAfter, nLineSpacing, nIndent, nFirstLine, cShading, lKeepNext, lPageBreakBefore )
nCenter  := oDoc:NewStyle( , 2 )
nJustify := oDoc:NewStyle( , 4, , 6, 1.15, , 1 )        // justified, 6 pt after, line 1.15, first line 1 cm
nQuote   := oDoc:NewStyle( nItalic, , 6, 6, , 1 )       // italic, 6 pt before/after, indented 1 cm
nBox     := oDoc:NewStyle( nBold, 1, , , , , , "DEEAF6" )  // light blue background
nChapter := oDoc:NewStyle( , , , , , , , , , .T. )      // starts on a new page

oDoc:Paragraph( "Centered", nCenter )
oDoc:Paragraph( cLongText, nJustify )
```

| Parameter | Values |
|---|---|
| `nAlign` | 1 left, 2 center, 3 right, 4 justified |
| `nSpaceBefore`, `nSpaceAfter` | points |
| `nLineSpacing` | multiple: 1, 1.15, 1.5, 2 |
| `nIndent`, `nFirstLine` | cm; a negative `nFirstLine` is a hanging indent |
| `cShading` | background color |

The font of a style is used for all text of the paragraph that has no font of its own.
A single paragraph can be aligned without a new style: `oP:nAlign := 3`.

### Title, headings, table of contents, page break

```harbour
oDoc:Title( "Annual report" )
oDoc:TableOfContents( "Contents", 3 )     // title, levels 1..3
oDoc:PageBreak()
oDoc:Heading( "Sales", 1 )
oDoc:Heading( "By region", 2 )
oDoc:Heading( "Notes", 2, nStyle )        // a heading can have an extra style
```

Headings use Word's built-in styles `heading 1` .. `heading 6`. Word fills the table of contents when the
document is opened (it asks to update the fields); in LibreOffice use *Tools - Update - Update All*.

### Lists

```harbour
// NewList( cType ): "bullet", "decimal", "lowerLetter", "upperLetter", "lowerRoman", "upperRoman"
nList := oDoc:NewList( "bullet" )
oDoc:ListItem( "First", nList )
oDoc:ListItem( "Nested", nList, 2 )       // level 1..9
oDoc:ListItem( "Second", nList )

nNum := oDoc:NewList( "decimal" )         // every list starts at 1
oDoc:ListItem( "Step one", nNum )
oDoc:ListItem( "Detail", nNum, 2 )        // a. b. c.
oDoc:ListItem( "Step two", nNum )
```

Without `nList` the last created list is continued (or a new bulleted list is created).

### Tables

```harbour
oTable := oDoc:Table( { 7, 2.5, 3, 3.5 } )     // column widths in cm; Table( 4 ) = 4 equal columns
oTable:nHeaderRows := 1                        // repeated at the top of every page
oTable:aPictures   := { , "@E 999,999", "@E 999,999.99", "@E 999,999.99" }   // Transform() per column

// AddRow( aValues, nStyle, cShading ) returns the row number
oTable:AddRow( { "Item", "Qty", "Price", "Amount" }, nHead, "305496" )
FOR EACH aItem IN aItems
   oTable:AddRow( { aItem[ 1 ], aItem[ 2 ], aItem[ 3 ], aItem[ 2 ] * aItem[ 3 ] } )
NEXT

nRow := oTable:AddRow()
oTable:Merge( nRow, 1, nRow, 3 )               // Merge( nRow1, nCol1, nRow2, nCol2 )
oTable:Cell( nRow, 1, "Total", nBoldRight )    // Cell( nRow, nCol, xValue, nStyle )
oTable:Cell( nRow, 4, nTotal, nBoldRight )
```

- Numbers without a style are right aligned. `oTable:aColStyles := { , nRight, nRight }` sets a style per column.
- `Shade( nRow, nCol, cColor )` colors a cell, or the whole row when `nCol` is `NIL`.
- `VAlign( nRow, nCol, n )` 1 top, 2 center, 3 bottom (whole row when `nCol` is `NIL`, whole table when `nRow` is `NIL`).
- `RowHeight( nRow, nCm )` minimal row height.
- `nBorder` 0 none, 1 single, 2 double, 3 dotted, 4 dashed, 5 thick; `nBorderSize` (pt), `cBorderColor`.
- `nAlign` 1 left, 2 center, 3 right (position of the table), `nCellMargin` (cm).

`Cell( nRow, nCol )` without a value returns the content of the cell, which works like the document itself:

```harbour
oCell := oTable:Cell( 1, 1 )
oCell:Picture( "logo.png", 3 )
oCell:Paragraph( "S.O.K. doo", nBold )
oTable:Cell( 2, 2 ):Table( 2 ):AddRow( { "nested", "table" } )
```

### Pictures

```harbour
oDoc:Picture( "logo.png", 5, , 2 )          // Picture( cFile, nWidth, nHeight, nAlign ): 5 cm wide, centered
oDoc:Picture( "photo.jpg" )                 // natural size (96 dpi), at most the width of the text
oDoc:Paragraph( "Signature: " ):Picture( "sign.png", , 1 ):Text( " (1 cm high)" )
```

With only the width or only the height the other side is proportional.
A missing file is skipped and `oDoc:cError` gets its name (check it before `Save()`, which clears `cError`).

### Charts

```harbour
// Chart( cTitle, cType, aCategories, aSeries, nWidth, nHeight, nAlign ) -> DocxChart
// cType: "bar" (columns), "hbar" (horizontal bars), "line", "area", "pie", "doughnut"
oChart := oDoc:Chart( "Sales 2026", "bar", { "Jan", "Feb", "Mar" }, ;
                      { { "Beograd", { 120, 150, 90 } }, { "Novi Sad", { 80, 95, 110 }, "70AD47" } }, , , 2 )
oChart:lValues    := .T.                     // values at the columns / points (pie: instead of percents)
oChart:cNumFormat := "#,##0"                 // axis and values
oChart:cValTitle  := "thousand RSD"          // axis titles: cValTitle, cCatTitle
oChart:lLegend    := .F.
oChart:aColors    := { "264478", "4472C4" }  // series colors (pie, doughnut: the slices)

oDoc:Chart( "Share", "pie", { "A", "B", "C" }, { 44, 32, 23 }, 12, 7 )   // one series: just the values
oTable:Cell( 1, 1 ):Chart( "Beograd", "line", aMonths, { aValues }, 7.5, 5 )
```

`aSeries` is `{ { cName, aValues [, cColor ] }, ... }` or only an array of numbers (one series); `oChart:AddSeries( cName, aValues, cColor )`
adds one more. A pie shows the first series. Default size: the width of the text (at most 15 cm), height 0.6 of the width.
The values are written into the chart (Word, LibreOffice draw it from them) and into an embedded workbook,
so right click - Edit Data in Word opens them in Excel.

### Header, footer, page setup

```harbour
oDoc:nPaperSize   := 9        // 9 A4, 1 Letter, 5 Legal, 8 A3, 11 A5
oDoc:lLandscape   := .T.
oDoc:nLeftMargin  := 2        // cm; also nRightMargin, nTopMargin, nBottomMargin, nHeaderMargin, nFooterMargin

// AddHeader( cLeft, cCenter, cRight, nFont ), AddFooter( ... )
// &P page, &N number of pages, &D date, &T time, &F file name, && = &
oDoc:AddHeader( "My Company", "", '&D' )
oDoc:AddFooter( '&F', "", 'Page &P of &N' )
```

> In Harbour `&N` inside a string literal is a macro when the function has a variable named `n`
> (error *E0042 Macro of declared symbol*). Rename the variable or write `"&" + "N"`.

Page numbering from another page and a cover page:

```harbour
oDoc:nPageStart := 15         // the first page is page 15: "Page 15 of 18" ... "Page 18 of 18"
oDoc:lTitlePage := .T.        // the first page (cover) has no header and footer
```

`Header()` and `Footer()` return the content of the header / footer for anything else:

```harbour
oDoc:Header():Picture( "logo.png", 3 )
oDoc:Footer():Paragraph( "Page ", nCenter ):PageNumber():Text( " of " ):PageCount()
```

Document defaults: `cFont` (`"Calibri"`), `nFontSize` (11), `nSpaceAfter` (8 pt), `nLineSpacing` (1.08),
`cLanguage` (`"en-US"`, the spell checking language, e.g. `"sr-Latn-RS"`).
Document properties: `cTitle`, `cSubject`, `cAuthor`, `cCompany`.

### PDF

The class writes the .docx itself; a PDF needs a program that lays out the pages:

```harbour
// SavePDF( cPdf, nEngine ): Save(), then the PDF (default name: the .docx name with .pdf)
// nEngine 0 = Word if installed, else LibreOffice; 1 = Word only; 2 = LibreOffice only
IF ! oDoc:SavePDF( "report.pdf" )
   ? oDoc:cError
ENDIF
```

- **Word** (Windows): through OLE when the program links `hbwin` and uses `win_oleCreateObject()` (or has
  `REQUEST WIN_OLECREATEOBJECT`), else through PowerShell - no extra library is needed. Word also updates
  the table of contents and the fields. Only the Word that `SavePDF()` started is closed: a Word the user
  has open is not hidden or closed. If that Word does not end after `Quit()` (a dialog, "Word is busy"),
  it is ended after 5 seconds - only that process, found by its PID.
- **LibreOffice** (Windows, Linux, macOS): `soffice --headless --convert-to pdf` with its own profile in the
  temp folder, so it works while LibreOffice is open. `soffice` is found in the registry, the usual folders
  and the `PATH`; or set `DOCX_SOFFICE=D:\LibreOffice\program\soffice.exe`. LibreOffice does not fill the
  table of contents (it shows the "Update Field" text); the first conversion takes longer (new profile).

### Digital signature of the PDF

`PDFSign.prg` signs any PDF - made by `SavePDF()`, by hbhpdf / libharu, by Word or LibreOffice - with a
certificate: a PAdES signature (`/SubFilter /adbe.pkcs7.detached`, CMS with SHA-256, the signing time and
the chain of certificates), visible on the page. The PDF is not rewritten: the signature is added at its
end (an incremental update), so a signed PDF can be signed again and the earlier signatures stay valid.

```harbour
// hbmk2 myapp.prg DOCXClass.prg PDFSign.prg pdfsignw.c hbmzip.hbc -lcrypt32
LOCAL cErr := ""
IF ! PDF_Sign( "report.pdf", "report_signed.pdf", { ;
        "row" => -6, "col" => 45, ;               // as @ nRow, nCol on a printer: 6 rows and 10 columns per inch
        "width" => 85, "height" => 18, ;          // mm
        "page" => 0, ;                            // the last page (1 = the first)
        "reason" => "Approval", "location" => "Marília - SP", ;
        "text" => { "Assinado digitalmente por {name}", "Data: {date}", "Motivo: {reason}" } }, @cErr )
   ? cErr
ENDIF
```

| Option | Meaning |
|---|---|
| `cert` | the thumbprint of a certificate in the Windows store (A1 installed, A3 token or card: Windows asks for the PIN); empty and no `pfx`: the window of Windows to choose one (`PDF_SelectCertificate()`) |
| `pfx`, `password` | a `.pfx` / `.p12` file instead (not installed); on Linux the only way (through `openssl`) |
| `row`, `col` | the top left corner of the signature in rows and columns from the top left of the page, 6 rows and 10 columns per inch; a negative `row`: the bottom of the signature that many rows above the bottom of the page |
| `top`, `left` | the same in mm |
| `width`, `height` | the size in mm (80 x 18) |
| `page` | 1 the first page, 0 the last (default), -1 the one before the last |
| `reason`, `location`, `contact` | shown in the signature panel of the reader |
| `text` | the lines of the signature: `{name}` (CN of the certificate), `{date}`, `{reason}`, `{location}`, `{issuer}` |
| `visible` | `.F.`: a signature without a picture on the page |
| `border`, `background` | the frame (`.T.`), a white field under the text (`.F.`) |
| `fontsize`, `size` | the font size (0: what fits), the room for the signature in bytes (20000) |
| `image` | a picture with the signature: a JPEG or PNG file (PNG with transparency too; 8 bits, not interlaced) |
| `imagepos` | `"left"` (default) or `"right"`: the picture as high as the signature, beside the text; `"back"`: under the text, over the whole signature |

```harbour
PDF_Sign( "report.pdf", "report_signed.pdf", { "image" => "stamp.png", "imagepos" => "left", ;
          "width" => 90, "height" => 22, "reason" => "Approval" }, @cErr )
```

`PDF_Certificates()` lists the personal certificates of Windows: `{ cThumbprint, cName, cIssuer, cValidTo, lHasKey }`.
In Serbia: the certificate of the ID card (MUP) or of a token (Pošta, Halcom, PKS, E-Smart ...) is in the
Windows store once the middleware of its issuer is installed, and is chosen and used like any other (Windows
asks for the PIN). The cloud signature of eUprava (ConsentID) is not in the store and cannot be used here.

A reader checks two things: that the PDF was not changed after signing (the signature itself), and that
it trusts the certificate. "Signature is invalid / the certificate of the signer is invalid" with a
certificate that is valid usually means the second: the reader does not trust its root, or cannot check
whether it was revoked. In Adobe Acrobat: Preferences - Signatures - Verification - Windows Integration,
"Trust all root certificates in the Windows Certificate Store" for validating signatures (the root of a
national PKI - ICP-Brasil, MUP Srbije ... - is there once its middleware is installed), or import the root
under Identities & Trusted Certificates as a trusted root. The signature panel (Signature Properties -
Show Signer's Certificate - Trust / Revocation) tells the exact reason.

`pdfsignw.c` also compiles with old Platform SDK headers (Borland bcc32 5.8, old MinGW): what they lack is
defined there.

Not done: encrypted PDFs; the text of the signature is Helvetica (the letters of Western Europe and
č ć đ š ž, no Cyrillic); the `/Rotate` of a page is not taken into account; no time stamp server (the time
is that of the computer).

### Coming from Word OLE automation

A program that makes documents by driving Word through OLE (`Word.Application`, `Selection`, `Range`) needs
Word on every computer and is slow. The same document with DOCXClass, without Word -
`samples/DOCXReport.prg` is a complete example (cover page, header with a logo, "Page X of Y", contents,
lists, a table with merged rows, signatures, PDF):

| Word OLE | DOCXClass |
|---|---|
| `Documents:Add()`, `SaveAs( cDoc )` | `oDoc := WordDocument():New( cDoc )`, `oDoc:Save()` |
| `PageSetup:Orientation`, `PaperSize`, `LeftMargin` (points) | `lLandscape`, `nPaperSize`, `nLeftMargin` (cm) |
| `Selection:Font:Name / Size / Bold`, `TypeText()` | `NewFont()`, `oDoc:Paragraph( cText ):Text( cMore, nFont )` |
| `ParagraphFormat:Alignment`, `SpaceAfter`, `LineSpacingRule` | `NewStyle( nFont, nAlign, nSpaceBefore, nSpaceAfter, nLineSpacing )` |
| `Style := "Heading 1"` | `oDoc:Heading( cText, 1 )` |
| `ListFormat:ApplyBulletDefault()` | `oDoc:ListItem( cText, nList, nLevel )` |
| `Tables:Add()`, `Cell( r, c ):Range:Text` | `oDoc:Table( aWidths )`, `AddRow( aValues )`, `Cell( r, c, xValue, nStyle )` |
| `Cell():Merge()`, `Shading`, `VerticalAlignment` | `Merge( r1, c1, r2, c2 )`, `Shade( r, c, cColor )`, `VAlign( r, c, n )` |
| `HeadingFormat := .T.` (repeat header row) | `oTable:nHeaderRows := 1` |
| `InlineShapes:AddPicture()` (also in a cell) | `oDoc:Picture( cFile, nWidth )`, `oTable:Cell( r, c ):Picture( cFile, nWidth )` |
| `Headers( 1 ):Range`, `Fields:Add( PAGE / NUMPAGES )` | `oDoc:Header():Table(...)`, `AddFooter( "", "", "Page &P of &N" )` |
| `{ = { PAGE } + 14 }` (numbering from page 15) | `oDoc:nPageStart := 15` |
| `DifferentFirstPageHeaderFooter` (cover page) | `oDoc:lTitlePage := .T.` |
| `TablesOfContents:Add()` | `oDoc:TableOfContents( "Contents" )` |
| `InsertBreak( 7 )` | `oDoc:PageBreak()` |
| `Find:Execute( ..., wdReplaceAll )` | `oDoc:Read( cTemplate )`, `oDoc:Replace( { "{{name}}" => cName } )` |
| `ExportAsFixedFormat( cPdf, 17 )` | `oDoc:SavePDF( cPdf )` |

### Text in another codepage (DBF data)

Text that is not valid UTF-8 is converted from `oDoc:cCodePage`.
The default is the application codepage at the time `WordDocument():New()` is called, so in most programs nothing has to be done.

```harbour
REQUEST HB_CODEPAGE_HRWIN

oDoc := WordDocument():New( "customers.docx" )
oDoc:cCodePage := "HRWIN"              // DBF data in Windows-1250
oDoc:Paragraph( customers->name )
```

Control characters (e.g. `Chr(0)` or `Chr(26)` left in DBF fields) are removed, because they are not allowed in XML.

### Templates

Make the document in Word and write placeholders where the data goes, e.g. `{{customer}}`, `{{date}}`.
For a table with items, write the placeholders in one row of the table. Then:

```harbour
oDoc := WordDocument():New()
IF ! oDoc:Read( "invoice_template.docx" )
   ? oDoc:cError
   RETURN
ENDIF

// Replace( cFind, xValue ) or Replace( hValues ); returns the number of replacements
oDoc:Replace( { "{{customer}}" => customers->name, ;
                "{{address}}"  => AllTrim( customers->street ) + Chr( 10 ) + customers->city, ;
                "{{date}}"     => Date() } )

// RepeatRow( cMarker, aRows [, aKeys ] ): the table row with cMarker is copied for every element
// of aRows. An element is a hash { "{{item}}" => "Pen", ... }, or an array of values when aKeys
// gives the placeholder names. An empty aRows removes the row.
aRows := {}
DO WHILE ! items->( Eof() )
   AAdd( aRows, { items->name, items->qty, Transform( items->price, "@E 999,999.99" ) } )
   items->( dbSkip() )
ENDDO
oDoc:RepeatRow( "{{item}}", aRows, { "{{item}}", "{{qty}}", "{{price}}" } )

// new content goes in place of the paragraph with {{notes}} (without InsertAt: at the end)
oDoc:InsertAt( "{{notes}}" )
oDoc:Heading( "Notes", 2 )
oDoc:Paragraph( "Payment within 15 days." )

oDoc:Save( "invoice_123.docx" )       // or oDoc:cName := "invoice_123.docx"; oDoc:Save()
```

- Placeholders are found also when Word split them into several parts (spell checking, editing, formatting);
  the new text gets the format of the first character of the placeholder.
- `Replace()` works in the body, headers, footers, footnotes and endnotes. `Chr(10)` in a value is a new line.
- The read document can be extended with everything from the previous chapters (paragraphs, tables, lists,
  pictures, links, a new header / footer). Missing styles are added; page setup of the file is kept.
- `Save()` can be called several times, e.g. to make many documents from one read template: read it again
  for every document, `Replace()` changes the read document.

### Reading a file

```harbour
oDoc := WordDocument():New()
IF oDoc:Read( "report.docx" )
   FOR EACH aPara IN oDoc:Paragraphs( .T. )     // without .T.: only the texts
      ? aPara[ 2 ], aPara[ 1 ]                  // style ("heading 1", "Title", "" ...), text
   NEXT
   FOR EACH aTable IN oDoc:Tables()             // table = array of rows, row = array of cell texts
      FOR EACH aRow IN aTable
         ? hb_ValToExp( aRow )
      NEXT
   NEXT
   ? oDoc:Text()                                // everything; table cells separated by Tab
ENDIF
```

- Paragraphs inside tables are returned only in `Tables()`; a cell with several paragraphs has them separated by `Chr(10)`.
- Merged cells: the first cell has the text, the covered ones are `""`, so all rows have the same number of columns.
- Text in text boxes is added to its paragraph; deleted text of tracked changes and field codes are skipped.
- Text is returned in UTF-8; for another codepage use e.g. `hb_Translate( x, "UTF8", "HRWIN" )`.

## Samples

| File | What it shows |
|---|---|
| `samples/DOCXWriter.prg` | title, table of contents, headings, formatted text, lists, tables with totals and merged cells, pictures, a link, header and footer |
| `samples/DOCXTemplate.prg` | creates `template.docx` with placeholders and fills it: replacements, repeated table rows, new content at a marker |
| `samples/DOCXReader.prg` | reads a document: paragraphs with styles, tables |
| `samples/DOCXReport.prg` | a report as made with Word OLE, without Word: cover page, header with a logo, "Page X of Y", contents, lists, a table with merged rows, signatures, `SavePDF()`; `docxreport sign`: the PDF signed with a certificate |
| `samples/DOCXSign.prg` | a contract made, saved as PDF and signed with a certificate; or any PDF signed at the row and column given (`docxsign file.pdf -6 45`) |
| `samples/DOCXChart.prg` | charts: column, line with values, horizontal bars in own colors, pie, doughnut, area, charts in a table cell |

## License, Donations & Commercial Use

Dual licensed: **GNU GPL version 3 or later** (`COPYING`) **or a commercial license** from the author, Srđan Dragojlović (`digikv@yahoo.com`).

* **Open-Source & Internal Use (GPLv3):** Free to use in open-source projects, for personal use, or strictly internally within a single company without distribution to third parties.
* **Commercial License (Closed-Source):** For closed-source programs distributed or sold to third parties, a one-time, perpetual company-wide commercial license is available for **150 EUR** (or **190 EUR** as a bundle together with the companion [`XLSXClass.prg`](https://github.com) library), covering unlimited internal developers and deployments.

### Support & Donations
If you use this library for personal, open-source, or internal projects and find it helpful, voluntary donations to support ongoing development are warmly appreciated:
* **PayPal:** `digikv@yahoo.com`

### How to Purchase a Commercial License
1. Send the payment (**150 EUR** for `DOCXClass.prg` or **190 EUR** for the `DOCXClass.prg` + `XLSXClass.prg` bundle) via **PayPal** to: `digikv@yahoo.com`
2. Include your **company name** and **email address** in the PayPal payment note (or send a confirmation email to `digikv@yahoo.com`).
3. You will receive your commercial license certificate by email.

See `LICENSE` for more details.
