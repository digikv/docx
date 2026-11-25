/*
 *
 * PDF digital signature with a certificate - Pure Harbour (+ pdfsignw.c on Windows)
 *
 * Copyright 2026 Srđan Dragojlović <digikv@yahoo.com>
 * Company  S.O.K. doo Kraljevo
 * www - https://sokdoo.com
 *
 * Dual licensed: GNU GPL version 3 or later (COPYING), or a commercial
 * license from the author - see LICENSE.
 *
 * Potpisuje bilo koji PDF (SavePDF() klase WordDocument, hbhpdf / libharu,
 * Word, LibreOffice ...) sertifikatom: PAdES osnovni potpis, /SubFilter
 * /adbe.pkcs7.detached (CMS, SHA-256), sa vidljivim potpisom na mestu koje
 * se zada. PDF se ne prepisuje: potpis se dodaje na kraj (incremental
 * update), pa se isti PDF moze potpisati vise puta.
 *
 *   PDF_Sign( cPdfIn, cPdfOut, hOptions, @cErr ) -> lOk
 *   PDF_Certificates()                  -> { { cThumbprint, cName, cIssuer, cValidTo, lHasKey }, ... }   (Windows)
 *   PDF_SelectCertificate( [cTitle] )   -> cThumbprint, "" = odustao                                    (Windows)
 *
 * hOptions (sve je opciono):
 *   "cert"      thumbprint sertifikata iz Windows prodavnice (A1, A3 token / kartica);
 *               prazno i bez "pfx": Windows dijalog za izbor sertifikata
 *   "pfx", "password"   sertifikat iz .pfx / .p12 fajla (Windows i Linux; na Linuxu preko openssl)
 *   "page"      strana: 1 prva, 0 poslednja (podrazumevano), -1 pretposlednja ...
 *   "row", "col"   polozaj gornjeg levog ugla potpisa u redovima i kolonama kao na
 *               stampacu (6 redova i 10 kolona po incu - @ nRow, nCol SAY), od vrha i
 *               leve ivice strane; negativan "row": koliko redova iznad donje ivice
 *               je donja ivica potpisa
 *   "top", "left"  isto, u milimetrima (umesto "row" / "col")
 *   "width", "height"  velicina potpisa u mm (podrazumevano 80 x 18)
 *   "visible"   .F.: potpis bez slike na strani
 *   "reason", "location", "contact"   razlog, mesto, kontakt
 *   "text"      redovi teksta potpisa: { "Assinado digitalmente por {name}", "Data: {date}" };
 *               {name} {date} {reason} {location} {issuer}
 *   "fontsize"  0 = koliko stane (podrazumevano)
 *   "border"    .F.: bez okvira
 *   "background"  .T.: belo polje ispod teksta (kad je potpis preko teksta strane)
 *   "size"      mesto za potpis u bajtovima (podrazumevano 20000)
 *   "image"     slika uz potpis: JPEG ili PNG fajl (PNG i sa providnoscu)
 *   "imagepos"  "left" (podrazumevano) / "right": slika u visini potpisa levo / desno
 *               od teksta; "back": slika ispod teksta, preko celog potpisa
 *
 * Ogranicenja: sifrovani PDF se ne potpisuje; tekst potpisa je Helvetica
 * (latinica zapadne Evrope i č ć đ š ž, bez cirilice); /Rotate strane se ne
 * uzima u obzir.
*/

#include "fileio.ch"

#define LPI_PT   12          // 6 redova po incu
#define CPI_PT   7.2         // 10 kolona po incu
#define MM_PT    ( 72 / 25.4 )

FUNCTION PDF_Sign( cIn, cOut, hOpt, cErr )

   LOCAL c, hPdf, nRoot, cCat, aPages, nPage, nPg, cPage, aBox, nW, nH, nX, nY, nPw, nPh
   LOCAL nNext, nSig, nWid, nAP, nFont, aInfo, cName, cThumb, cPfx, cPass, cUpd, aObj := {}
   LOCAL cAF, nAF, cFields, nFields, cAnnots, nAnnots, cAp, cSigDict, cWid, cDate, dNow
   LOCAL nSize, cAll, nBR, nCt, nA, nB, cDer, cHex, cBR, lVisible, aLines, nFs, cOld
   LOCAL nPrevXref, lStream, cTrailer
   LOCAL hImg, nImg, nSMask, cImgPos, nIw, nIh, nIx, nIy, nTx := 3, nTextW, cImgOps := ""

   cErr := ""
   hOpt := IIF( HB_ISHASH( hOpt ), hOpt, { => } )
   c := hb_MemoRead( cIn )
   IF hb_BLen( c ) < 20 .OR. ! hb_BLeft( c, 5 ) == "%PDF-"
      cErr := "Not a PDF: " + cIn
      RETURN .F.
   ENDIF

   /* the certificate */
   cThumb := hb_HGetDef( hOpt, "cert", "" )
   cPfx := hb_HGetDef( hOpt, "pfx", "" )
   cPass := hb_HGetDef( hOpt, "password", "" )
   IF Empty( cPfx ) .AND. Empty( cThumb )
#if defined( __PLATFORM__WINDOWS )
      cThumb := PDF_SelectCertificate()
      IF Empty( cThumb )
         cErr := "No certificate chosen"
         RETURN .F.
      ENDIF
#else
      cErr := "No certificate: give hOptions[ 'pfx' ] and [ 'password' ]"
      RETURN .F.
#endif
   ENDIF
   aInfo := _PS_CertInfo( cThumb, cPfx, cPass, @cErr )
   IF aInfo == NIL
      RETURN .F.
   ENDIF
   cName := aInfo[ 1 ]

   /* the structure of the PDF */
   hPdf := _PS_Open( c, @cErr )
   IF hPdf == NIL
      RETURN .F.
   ENDIF
   cTrailer := hPdf[ "trailer" ]
   IF ! Empty( _PS_DictGet( cTrailer, "/Encrypt" ) )
      cErr := "The PDF is encrypted"
      RETURN .F.
   ENDIF
   nRoot := _PS_Ref( _PS_DictGet( cTrailer, "/Root" ) )
   cCat := _PS_Obj( hPdf, nRoot )
   IF nRoot == 0 .OR. Empty( cCat )
      cErr := "The PDF has no catalog (/Root)"
      RETURN .F.
   ENDIF
   aPages := {}
   _PS_Pages( hPdf, _PS_Ref( _PS_DictGet( cCat, "/Pages" ) ), aPages, 0 )
   IF Len( aPages ) == 0
      cErr := "The PDF has no pages"
      RETURN .F.
   ENDIF
   nPage := hb_HGetDef( hOpt, "page", 0 )
   nPage := IIF( nPage >= 1, Min( nPage, Len( aPages ) ), Max( 1, Len( aPages ) + nPage ) )
   nPg := aPages[ nPage ]
   cPage := _PS_Obj( hPdf, nPg )
   aBox := _PS_Box( hPdf, nPg )

   /* the place of the signature on the page (PDF: points from the bottom left) */
   lVisible := hb_HGetDef( hOpt, "visible", .T. )
   nPw := aBox[ 3 ] - aBox[ 1 ]
   nPh := aBox[ 4 ] - aBox[ 2 ]
   nW := hb_HGetDef( hOpt, "width", 80 ) * MM_PT
   nH := hb_HGetDef( hOpt, "height", 18 ) * MM_PT
   IF hb_HHasKey( hOpt, "left" )
      nX := hb_HGetDef( hOpt, "left", 0 ) * MM_PT
   ELSE
      nX := hb_HGetDef( hOpt, "col", 10 ) * CPI_PT
   ENDIF
   IF hb_HHasKey( hOpt, "top" )
      nY := nPh - hb_HGetDef( hOpt, "top", 0 ) * MM_PT - nH
   ELSEIF hb_HGetDef( hOpt, "row", 0 ) < 0
      nY := - hOpt[ "row" ] * LPI_PT
   ELSE
      nY := nPh - hb_HGetDef( hOpt, "row", 3 ) * LPI_PT - nH
   ENDIF
   nX += aBox[ 1 ]
   nY += aBox[ 2 ]
   IF ! lVisible
      nW := nH := nX := nY := 0
   ENDIF

   dNow := hb_DateTime()
   cDate := hb_TToS( dNow )
   cDate := DToC( hb_TToD( dNow ) ) + " " + SubStr( cDate, 9, 2 ) + ":" + SubStr( cDate, 11, 2 ) + ":" + SubStr( cDate, 13, 2 )
   nNext := hPdf[ "size" ]
   nSig := nNext++
   nWid := nNext++
   nAP := nNext++
   nFont := nNext++

   /* a picture with the signature (JPEG / PNG) */
   IF lVisible .AND. ! Empty( hb_HGetDef( hOpt, "image", "" ) )
      IF ( hImg := _PS_Image( hOpt[ "image" ], @cErr ) ) == NIL
         RETURN .F.
      ENDIF
      nImg := nNext++
      IF hImg[ "smask" ] != NIL
         nSMask := nNext++
      ENDIF
   ENDIF

   /* the signature: the place of /Contents is filled after the bytes are known */
   nSize := Max( 8000, hb_HGetDef( hOpt, "size", 20000 ) )
   cSigDict := "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached" + ;
               " /ByteRange [0 0000000000 0000000000 0000000000]" + ;
               " /Contents <" + Replicate( "0", nSize * 2 ) + ">" + ;
               " /M " + _PS_Date( dNow ) + " /Name " + _PS_Text( cName ) + ;
               IIF( Empty( hb_HGetDef( hOpt, "reason", "" ) ), "", " /Reason " + _PS_Text( hOpt[ "reason" ] ) ) + ;
               IIF( Empty( hb_HGetDef( hOpt, "location", "" ) ), "", " /Location " + _PS_Text( hOpt[ "location" ] ) ) + ;
               IIF( Empty( hb_HGetDef( hOpt, "contact", "" ) ), "", " /ContactInfo " + _PS_Text( hOpt[ "contact" ] ) ) + " >>"
   AAdd( aObj, { nSig, cSigDict } )

   /* the field and its widget on the page */
   cWid := "<< /Type /Annot /Subtype /Widget /FT /Sig /T " + _PS_Text( "Signature" + hb_ntos( nWid ) ) + ;
           " /V " + hb_ntos( nSig ) + " 0 R /F 132 /P " + hb_ntos( nPg ) + " 0 R" + ;
           " /Rect [" + _PS_N( nX ) + " " + _PS_N( nY ) + " " + _PS_N( nX + nW ) + " " + _PS_N( nY + nH ) + "]" + ;
           " /AP << /N " + hb_ntos( nAP ) + " 0 R >> >>"
   AAdd( aObj, { nWid, cWid } )

   /* what is seen: the lines of text in a frame */
   aLines := {}
   FOR EACH cOld IN hb_HGetDef( hOpt, "text", { "Digitally signed by {name}", "Date: {date}", "{reason}", "{location}" } )
      cOld := StrTran( StrTran( StrTran( StrTran( StrTran( cOld, "{name}", cName ), "{date}", cDate ), ;
              "{reason}", hb_HGetDef( hOpt, "reason", "" ) ), "{location}", hb_HGetDef( hOpt, "location", "" ) ), ;
              "{issuer}", aInfo[ 3 ] )
      IF ! Empty( cOld )
         AAdd( aLines, cOld )
      ENDIF
   NEXT
   /* the picture: its place in the frame (the proportions kept), the text beside it */
   nTextW := nW - 6
   IF hImg != NIL
      cImgPos := Lower( AllTrim( hb_HGetDef( hOpt, "imagepos", "left" ) ) )
      IF cImgPos == "back"
         nIw := Min( ( nW - 2 ) / hImg[ "w" ], ( nH - 2 ) / hImg[ "h" ] )
         nIh := hImg[ "h" ] * nIw
         nIw := hImg[ "w" ] * nIw
         nIx := ( nW - nIw ) / 2
      ELSE
         nIh := nH - 4
         nIw := nIh * hImg[ "w" ] / hImg[ "h" ]
         IF nIw > nW / 2
            nIw := nW / 2
            nIh := nIw * hImg[ "h" ] / hImg[ "w" ]
         ENDIF
         nTextW := nW - nIw - 9
         IF cImgPos == "right"
            nIx := nW - 2 - nIw
         ELSE
            nIx := 2
            nTx := nIx + nIw + 3
         ENDIF
      ENDIF
      nIy := ( nH - nIh ) / 2
      cImgOps := "q " + _PS_N( nIw ) + " 0 0 " + _PS_N( nIh ) + " " + _PS_N( nIx ) + " " + _PS_N( nIy ) + " cm /Im1 Do Q" + Chr( 10 )
      AAdd( aObj, { nImg, "<< /Type /XObject /Subtype /Image /Width " + hb_ntos( hImg[ "w" ] ) + ;
                          " /Height " + hb_ntos( hImg[ "h" ] ) + " " + hImg[ "dict" ] + ;
                          IIF( nSMask == NIL, "", " /SMask " + hb_ntos( nSMask ) + " 0 R" ) + ;
                          " /Length " + hb_ntos( hb_BLen( hImg[ "data" ] ) ) + " >>" + Chr( 10 ) + ;
                          "stream" + Chr( 10 ) + hImg[ "data" ] + Chr( 10 ) + "endstream" } )
      IF nSMask != NIL
         AAdd( aObj, { nSMask, "<< /Type /XObject /Subtype /Image /Width " + hb_ntos( hImg[ "w" ] ) + ;
                               " /Height " + hb_ntos( hImg[ "h" ] ) + " /ColorSpace /DeviceGray /BitsPerComponent 8" + ;
                               " /Filter /FlateDecode /Length " + hb_ntos( hb_BLen( hImg[ "smask" ] ) ) + " >>" + Chr( 10 ) + ;
                               "stream" + Chr( 10 ) + hImg[ "smask" ] + Chr( 10 ) + "endstream" } )
      ENDIF
   ENDIF
   nFs := hb_HGetDef( hOpt, "fontsize", 0 )
   IF nFs <= 0 .AND. lVisible
      nFs := Min( 9, ( nH - 4 ) / ( Max( 1, Len( aLines ) ) * 1.2 ) )
      AEval( aLines, {| x | nFs := Min( nFs, Max( 1, nTextW ) / Max( 1, Len( x ) * 0.52 ) ) } )
      nFs := Max( 3, nFs )
   ENDIF
   cAp := _PS_Appearance( aLines, nW, nH, nFs, hb_HGetDef( hOpt, "border", .T. ) .AND. lVisible, hb_HGetDef( hOpt, "background", .F. ), ;
                          nTx, cImgOps )
   AAdd( aObj, { nAP, "<< /Type /XObject /Subtype /Form /BBox [0 0 " + _PS_N( nW ) + " " + _PS_N( nH ) + "]" + ;
                      " /Resources << /Font << /F1 " + hb_ntos( nFont ) + " 0 R >>" + ;
                      IIF( nImg == NIL, "", " /XObject << /Im1 " + hb_ntos( nImg ) + " 0 R >>" ) + ;
                      " >> /Length " + hb_ntos( hb_BLen( cAp ) ) + ;
                      " >>" + Chr( 10 ) + "stream" + Chr( 10 ) + cAp + Chr( 10 ) + "endstream" } )
   /* WinAnsi, and in its unused codes the letters of Serbian / Croatian it has not (c c d) */
   AAdd( aObj, { nFont, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Type /Encoding" + ;
                        " /BaseEncoding /WinAnsiEncoding /Differences [127 /dcroat 129 /Ccaron 141 /ccaron" + ;
                        " 143 /Cacute 144 /cacute 157 /Dcroat] >> >>" } )

   /* the field into /AcroForm of the catalog */
   cAF := _PS_DictGet( cCat, "/AcroForm" )
   nAF := _PS_Ref( cAF )
   IF nAF > 0
      cAF := _PS_Obj( hPdf, nAF )
   ENDIF
   IF Empty( cAF )
      cAF := "<< >>"
   ENDIF
   cFields := _PS_DictGet( cAF, "/Fields" )
   nFields := _PS_Ref( cFields )
   IF nFields > 0
      AAdd( aObj, { nFields, _PS_ArrAdd( _PS_Obj( hPdf, nFields ), nWid ) } )
   ELSE
      cAF := _PS_DictSet( cAF, "/Fields", _PS_ArrAdd( cFields, nWid ) )
   ENDIF
   cAF := _PS_DictSet( cAF, "/SigFlags", "3" )
   IF nAF > 0
      AAdd( aObj, { nAF, cAF } )
   ELSE
      cCat := _PS_DictSet( cCat, "/AcroForm", cAF )
      AAdd( aObj, { nRoot, cCat } )
   ENDIF

   /* the widget into /Annots of the page */
   cAnnots := _PS_DictGet( cPage, "/Annots" )
   nAnnots := _PS_Ref( cAnnots )
   IF nAnnots > 0
      AAdd( aObj, { nAnnots, _PS_ArrAdd( _PS_Obj( hPdf, nAnnots ), nWid ) } )
   ELSE
      AAdd( aObj, { nPg, _PS_DictSet( cPage, "/Annots", _PS_ArrAdd( cAnnots, nWid ) ) } )
   ENDIF

   /* the update: the objects, a new xref section, the trailer */
   cAll := c
   IF ! hb_BRight( cAll, 1 ) $ Chr( 10 ) + Chr( 13 )
      cAll += Chr( 10 )
   ENDIF
   nPrevXref := hPdf[ "startxref" ]
   lStream := hPdf[ "xrefstream" ]
   cUpd := _PS_Update( cAll, aObj, hPdf, nPrevXref, lStream, nNext )
   cAll += cUpd

   /* /ByteRange: all but the hex of /Contents */
   nBR := hb_BAt( "/ByteRange [0 0000000000 0000000000 0000000000]", cAll, hb_BLen( c ) )
   nCt := hb_BAt( "/Contents <" + Replicate( "0", 16 ), cAll, nBR ) + 10      // the "<"
   nA := nCt - 1                                    // bytes before "<"
   nB := nCt + nSize * 2 + 1                         // 0-based: after ">"
   cBR := "/ByteRange [0 " + hb_ntos( nA ) + " " + hb_ntos( nB ) + " " + hb_ntos( hb_BLen( cAll ) - nB ) + "]"
   cBR := hb_BPadR( cBR, hb_BLen( "/ByteRange [0 0000000000 0000000000 0000000000]" ) )
   cAll := hb_BLeft( cAll, nBR - 1 ) + cBR + hb_BSubStr( cAll, nBR + hb_BLen( cBR ) )

   cDer := _PS_CmsSign( hb_BLeft( cAll, nA ) + hb_BSubStr( cAll, nB + 1 ), cThumb, cPfx, cPass, @cErr )
   IF Empty( cDer )
      RETURN .F.
   ENDIF
   cHex := hb_StrToHex( cDer )
   IF hb_BLen( cHex ) > nSize * 2
      cErr := "The signature is " + hb_ntos( hb_BLen( cDer ) ) + " bytes: give hOptions[ 'size' ] bigger"
      RETURN .F.
   ENDIF
   cAll := hb_BLeft( cAll, nCt ) + cHex + hb_BSubStr( cAll, nCt + 1 + hb_BLen( cHex ) )
   IF ! hb_MemoWrit( cOut, cAll )
      cErr := "Cannot write " + cOut
      RETURN .F.
   ENDIF
   HB_SYMBOL_UNUSED( nPw )

RETURN .T.

FUNCTION PDF_Certificates()
#if defined( __PLATFORM__WINDOWS )
RETURN PDFS_CERTS()
#else
RETURN {}
#endif

FUNCTION PDF_SelectCertificate( cTitle )
#if defined( __PLATFORM__WINDOWS )
RETURN PDFS_SELECTCERT( hb_defaultValue( cTitle, "Certificate" ), "Choose the certificate to sign the document with" )
#else
HB_SYMBOL_UNUSED( cTitle )
RETURN ""
#endif

/*---------------------------------------------------------------- the certificate */

/* { cName, cSubject, cIssuer, cValidTo, cSerial } / NIL */
STATIC FUNCTION _PS_CertInfo( cThumb, cPfx, cPass, cErr )
#if defined( __PLATFORM__WINDOWS )
RETURN PDFS_CERTINFO( cThumb, cPfx, cPass, @cErr )
#else
LOCAL cPem, cOut := "", cErrOut := "", cCN := "", n, cIss := "", cSubj := ""
HB_SYMBOL_UNUSED( cThumb )
IF Empty( cPfx )
   cErr := "On this system only a .pfx certificate can be used"
   RETURN NIL
ENDIF
cPem := _PS_Pem( cPfx, cPass, "-clcerts -nokeys", @cErr )
IF Empty( cPem )
   RETURN NIL
ENDIF
hb_processRun( "openssl x509 -in " + cPem + " -noout -subject -issuer -nameopt RFC2253,-esc_msb", , @cOut, @cErrOut )
FErase( cPem )
FOR EACH n IN hb_ATokens( StrTran( cOut, Chr( 13 ), "" ), Chr( 10 ) )
   IF Left( n, 8 ) == "subject="
      cSubj := SubStr( n, 9 )
      cCN := _PS_RdnCN( cSubj )
   ELSEIF Left( n, 7 ) == "issuer="
      cIss := _PS_RdnCN( SubStr( n, 8 ) )
   ENDIF
NEXT
IF Empty( cCN )
   cErr := "Cannot read the certificate of " + cPfx + " " + cErrOut
   RETURN NIL
ENDIF
RETURN { cCN, cSubj, cIss, "", "" }
#endif

STATIC FUNCTION _PS_CmsSign( cData, cThumb, cPfx, cPass, cErr )
#if defined( __PLATFORM__WINDOWS )
RETURN PDFS_SIGN( cData, cThumb, cPfx, cPass, @cErr )
#else
LOCAL cCert, cKey, cChain, cIn := hb_DirTemp() + "pdfsign_" + hb_ntos( hb_RandomInt( 1, 999999 ) ), cDer, cOut := "", cErrOut := ""
HB_SYMBOL_UNUSED( cThumb )
cCert := _PS_Pem( cPfx, cPass, "-clcerts -nokeys", @cErr )
cKey := _PS_Pem( cPfx, cPass, "-nocerts -nodes", @cErr )
cChain := _PS_Pem( cPfx, cPass, "-cacerts -nokeys", @cErr )
IF Empty( cCert ) .OR. Empty( cKey )
   FErase( cCert )
   FErase( cKey )
   FErase( cChain )
   RETURN ""
ENDIF
cErr := ""
hb_MemoWrit( cIn + ".bin", cData )
hb_processRun( "openssl cms -sign -binary -nosmimecap -md sha256 -outform DER -in " + cIn + ".bin" + ;
               " -signer " + cCert + " -inkey " + cKey + IIF( Empty( cChain ), "", " -certfile " + cChain ) + ;
               " -out " + cIn + ".der", , @cOut, @cErrOut )
cDer := hb_MemoRead( cIn + ".der" )
FErase( cCert )
FErase( cKey )
FErase( cChain )
FErase( cIn + ".bin" )
FErase( cIn + ".der" )
IF Empty( cDer )
   cErr := "openssl cms: " + cErrOut
ENDIF
RETURN cDer
#endif

#if ! defined( __PLATFORM__WINDOWS )
/* a part of the .pfx as a PEM file in the temp folder (cWhat: "-clcerts -nokeys" the
   certificate, "-nocerts -nodes" the key, "-cacerts -nokeys" the chain); deleted by the
   caller; "" = none */
STATIC FUNCTION _PS_Pem( cPfx, cPass, cWhat, cErr )
LOCAL cPem := hb_DirTemp() + "pdfsign_" + hb_ntos( hb_RandomInt( 1, 999999 ) ) + ".pem", cOut := "", cErrOut := ""
hb_SetEnv( "PDFSIGN_PASS", cPass )
hb_processRun( "openssl pkcs12 -in " + cPfx + " -passin env:PDFSIGN_PASS " + cWhat + " -out " + cPem, , @cOut, @cErrOut )
IF ! "BEGIN" $ hb_MemoRead( cPem )                    // OpenSSL 3 and an old .pfx (RC2, 3DES)
   hb_processRun( "openssl pkcs12 -legacy -in " + cPfx + " -passin env:PDFSIGN_PASS " + cWhat + " -out " + cPem, , @cOut, @cErrOut )
ENDIF
hb_SetEnv( "PDFSIGN_PASS", "" )
IF ! "BEGIN" $ hb_MemoRead( cPem )
   FErase( cPem )
   IF ! "-cacerts" $ cWhat
      cErr := "Cannot open " + cPfx + " (wrong password?) " + cErrOut
   ENDIF
   RETURN ""
ENDIF
RETURN cPem

STATIC FUNCTION _PS_RdnCN( c )
LOCAL n := At( "CN=", c ), cCN
IF n == 0
   RETURN c
ENDIF
cCN := SubStr( c, n + 3 )
n := At( ",", cCN )
DO WHILE n > 1 .AND. SubStr( cCN, n - 1, 1 ) == "\"
   n := hb_At( ",", cCN, n + 1 )
ENDDO
RETURN StrTran( IIF( n > 0, Left( cCN, n - 1 ), cCN ), "\", "" )
#endif

/*---------------------------------------------------------------- reading the PDF */

/* the xref of the PDF: { "data", "xref" (n -> { nType, nOffset or nStream, nGen or nIndex }),
   "trailer", "size", "startxref", "xrefstream" } */
STATIC FUNCTION _PS_Open( c, cErr )

   LOCAL hPdf := { "data" => c, "xref" => { => }, "trailer" => "", "size" => 0, "startxref" => 0, ;
                   "xrefstream" => .F., "objstm" => { => } }
   LOCAL n := hb_BRAt( "startxref", c ), p, nOff, aSeen := {}

   IF n == 0
      cErr := "The PDF has no startxref"
      RETURN NIL
   ENDIF
   p := n + 9
   nOff := Val( _PS_Token( c, @p ) )
   hPdf[ "startxref" ] := nOff
   DO WHILE nOff > 0 .AND. AScan( aSeen, nOff ) == 0 .AND. nOff < hb_BLen( c )
      AAdd( aSeen, nOff )
      nOff := _PS_XrefSection( hPdf, nOff, Len( aSeen ) == 1, @cErr )
      IF nOff < 0
         RETURN NIL
      ENDIF
   ENDDO
   hPdf[ "size" ] := Max( Val( _PS_DictGet( hPdf[ "trailer" ], "/Size" ) ), _PS_MaxObj( hPdf[ "xref" ] ) + 1 )

RETURN hPdf

STATIC FUNCTION _PS_MaxObj( h )

   LOCAL n := 0, k

   FOR EACH k IN hb_HKeys( h )
      n := Max( n, k )
   NEXT

RETURN n

/* one xref section (a table or a stream); the offset of the previous one, 0 = none, -1 = error */
STATIC FUNCTION _PS_XrefSection( hPdf, nOff, lNewest, cErr )

   LOCAL c := hPdf[ "data" ], p := nOff + 1, cTok, nFirst, nCount, i, cO, cG, cT, cTr, nEnd, cDict, cData
   LOCAL aW, aIndex, nRow, nRows, nType, nF2, nF3, k, j, nPos, nX

   p := _PS_Skip( c, p )
   IF hb_BSubStr( c, p, 4 ) == "xref"
      p += 4
      DO WHILE .T.
         p := _PS_Skip( c, p )
         IF hb_BSubStr( c, p, 7 ) == "trailer" .OR. p > hb_BLen( c )
            EXIT
         ENDIF
         nFirst := Val( _PS_Token( c, @p ) )
         nCount := Val( _PS_Token( c, @p ) )
         FOR i := 0 TO nCount - 1
            cO := _PS_Token( c, @p )
            cG := _PS_Token( c, @p )
            cT := _PS_Token( c, @p )
            IF ! hb_HHasKey( hPdf[ "xref" ], nFirst + i )
               hPdf[ "xref" ][ nFirst + i ] := { IIF( cT == "n", 1, 0 ), Val( cO ), Val( cG ) }
            ENDIF
         NEXT
      ENDDO
      p := _PS_Skip( c, p + 7 )
      nEnd := _PS_ValueEnd( c, p )
      cTr := hb_BSubStr( c, p, nEnd - p )
      IF lNewest
         hPdf[ "trailer" ] := cTr
      ENDIF
      /* a hybrid file: the stream of /XRefStm belongs to this section */
      IF ( k := Val( _PS_DictGet( cTr, "/XRefStm" ) ) ) > 0
         _PS_XrefSection( hPdf, k, .F., @cErr )
      ENDIF
      cTok := _PS_DictGet( cTr, "/Prev" )
      RETURN IIF( Empty( cTok ), 0, Val( cTok ) )
   ENDIF

   /* an xref stream: "n g obj << /Type /XRef ... >> stream" */
   cDict := _PS_ObjAt( c, nOff + 1, @nPos )
   IF ! "/XRef" $ cDict
      cErr := "Unknown xref at " + hb_ntos( nOff )
      RETURN -1
   ENDIF
   IF lNewest
      hPdf[ "trailer" ] := cDict
      hPdf[ "xrefstream" ] := .T.
   ENDIF
   cData := _PS_StreamData( hPdf, cDict, nPos )
   aW := _PS_Nums( _PS_DictGet( cDict, "/W" ) )
   aIndex := _PS_Nums( _PS_DictGet( cDict, "/Index" ) )
   IF Len( aIndex ) == 0
      aIndex := { 0, Val( _PS_DictGet( cDict, "/Size" ) ) }
   ENDIF
   IF Len( aW ) < 3
      cErr := "Wrong /W in the xref stream"
      RETURN -1
   ENDIF
   nRow := aW[ 1 ] + aW[ 2 ] + aW[ 3 ]
   nRows := 0
   FOR k := 1 TO Len( aIndex ) - 1 STEP 2
      FOR j := 0 TO aIndex[ k + 1 ] - 1
         nX := nRows * nRow + 1
         nRows++
         nType := IIF( aW[ 1 ] == 0, 1, _PS_BE( cData, nX, aW[ 1 ] ) )
         nF2 := _PS_BE( cData, nX + aW[ 1 ], aW[ 2 ] )
         nF3 := _PS_BE( cData, nX + aW[ 1 ] + aW[ 2 ], aW[ 3 ] )
         IF ! hb_HHasKey( hPdf[ "xref" ], aIndex[ k ] + j )
            hPdf[ "xref" ][ aIndex[ k ] + j ] := { nType, nF2, nF3 }
         ENDIF
      NEXT
   NEXT
   cTok := _PS_DictGet( cDict, "/Prev" )

RETURN IIF( Empty( cTok ), 0, Val( cTok ) )

/* a big endian number of nLen bytes */
STATIC FUNCTION _PS_BE( c, nPos, nLen )

   LOCAL n := 0, i

   FOR i := 0 TO nLen - 1
      n := n * 256 + hb_BPeek( c, nPos + i )
   NEXT

RETURN n

/* the dictionary of an indirect object at p ("n g obj <<...>>"); nAfter: after the dictionary */
STATIC FUNCTION _PS_ObjAt( c, p, nAfter )

   LOCAL n := hb_BAt( "obj", c, p ), nEnd

   IF n == 0
      RETURN ""
   ENDIF
   n := _PS_Skip( c, n + 3 )
   nEnd := _PS_ValueEnd( c, n )
   nAfter := nEnd

RETURN hb_BSubStr( c, n, nEnd - n )

/* the decoded data of the stream whose dictionary ends at nAfter */
STATIC FUNCTION _PS_StreamData( hPdf, cDict, nAfter )

   LOCAL c := hPdf[ "data" ], p := hb_BAt( "stream", c, nAfter ), nLen, cLen, cData, cFilter, cParms, nPred, nCols

   IF p == 0
      RETURN ""
   ENDIF
   p += 6
   IF hb_BSubStr( c, p, 1 ) == Chr( 13 )
      p++
   ENDIF
   IF hb_BSubStr( c, p, 1 ) == Chr( 10 )
      p++
   ENDIF
   cLen := _PS_DictGet( cDict, "/Length" )
   IF _PS_Ref( cLen ) > 0
      cLen := _PS_Obj( hPdf, _PS_Ref( cLen ) )
   ENDIF
   nLen := Val( cLen )
   IF nLen <= 0
      nLen := hb_BAt( "endstream", c, p ) - p
   ENDIF
   cData := hb_BSubStr( c, p, nLen )
   cFilter := _PS_DictGet( cDict, "/Filter" )
   IF "FlateDecode" $ cFilter
      cData := hb_ZUncompress( cData )
      cParms := _PS_DictGet( cDict, "/DecodeParms" )
      nPred := Val( _PS_DictGet( cParms, "/Predictor" ) )
      IF nPred >= 10
         nCols := Val( _PS_DictGet( cParms, "/Columns" ) )
         cData := _PS_PngUndo( cData, IIF( nCols > 0, nCols, 1 ) )
      ENDIF
   ENDIF

RETURN cData

/* the PNG predictors of an xref / object stream undone (rows of 1 + nCols bytes) */
STATIC FUNCTION _PS_PngUndo( cData, nCols )

   LOCAL cOut := "", aPrev := Array( nCols ), aCur := Array( nCols ), nRow, i, nType, nA, nB, nC, nP, nRows

   AFill( aPrev, 0 )
   nRows := Int( hb_BLen( cData ) / ( nCols + 1 ) )
   FOR nRow := 0 TO nRows - 1
      nType := hb_BPeek( cData, nRow * ( nCols + 1 ) + 1 )
      FOR i := 1 TO nCols
         aCur[ i ] := hb_BPeek( cData, nRow * ( nCols + 1 ) + 1 + i )
         nA := IIF( i > 1, aCur[ i - 1 ], 0 )
         nB := aPrev[ i ]
         nC := IIF( i > 1, aPrev[ i - 1 ], 0 )
         SWITCH nType
         CASE 1 ; aCur[ i ] := ( aCur[ i ] + nA ) % 256 ; EXIT
         CASE 2 ; aCur[ i ] := ( aCur[ i ] + nB ) % 256 ; EXIT
         CASE 3 ; aCur[ i ] := ( aCur[ i ] + Int( ( nA + nB ) / 2 ) ) % 256 ; EXIT
         CASE 4
            nP := nA + nB - nC
            aCur[ i ] := ( aCur[ i ] + IIF( Abs( nP - nA ) <= Abs( nP - nB ) .AND. Abs( nP - nA ) <= Abs( nP - nC ), nA, ;
                                            IIF( Abs( nP - nB ) <= Abs( nP - nC ), nB, nC ) ) ) % 256
            EXIT
         ENDSWITCH
         cOut += hb_BChar( aCur[ i ] )
      NEXT
      aPrev := AClone( aCur )
   NEXT

RETURN cOut

/* the text of object n (its dictionary / array / value); "" when there is none */
STATIC FUNCTION _PS_Obj( hPdf, n )

   LOCAL a, c, nAfter, cDict, cData, nN, nFirst, p, i, aOff, nStart, nEnd

   IF n <= 0 .OR. ! hb_HHasKey( hPdf[ "xref" ], n )
      RETURN ""
   ENDIF
   a := hPdf[ "xref" ][ n ]
   c := hPdf[ "data" ]
   IF a[ 1 ] == 1
      RETURN _PS_ObjAt( c, a[ 2 ] + 1, @nAfter )
   ENDIF
   IF a[ 1 ] != 2
      RETURN ""
   ENDIF
   /* in an object stream: its header "num offset num offset ...", the objects after /First */
   IF ! hb_HHasKey( hPdf[ "objstm" ], a[ 2 ] )
      IF ! hb_HHasKey( hPdf[ "xref" ], a[ 2 ] ) .OR. hPdf[ "xref" ][ a[ 2 ] ][ 1 ] != 1
         RETURN ""
      ENDIF
      cDict := _PS_ObjAt( c, hPdf[ "xref" ][ a[ 2 ] ][ 2 ] + 1, @nAfter )
      hPdf[ "objstm" ][ a[ 2 ] ] := { cDict, _PS_StreamData( hPdf, cDict, nAfter ) }
   ENDIF
   cDict := hPdf[ "objstm" ][ a[ 2 ] ][ 1 ]
   cData := hPdf[ "objstm" ][ a[ 2 ] ][ 2 ]
   nN := Val( _PS_DictGet( cDict, "/N" ) )
   nFirst := Val( _PS_DictGet( cDict, "/First" ) )
   p := 1
   aOff := {}
   FOR i := 1 TO nN
      AAdd( aOff, { Val( _PS_Token( cData, @p ) ), Val( _PS_Token( cData, @p ) ) } )
   NEXT
   i := AScan( aOff, {| x | x[ 1 ] == n } )
   IF i == 0
      RETURN ""
   ENDIF
   nStart := _PS_Skip( cData, nFirst + aOff[ i ][ 2 ] + 1 )
   nEnd := _PS_ValueEnd( cData, nStart )

RETURN hb_BSubStr( cData, nStart, nEnd - nStart )

/* the pages in their order (the /Kids of /Pages) */
STATIC PROCEDURE _PS_Pages( hPdf, n, aPages, nDepth )

   LOCAL cD := _PS_Obj( hPdf, n ), cKids, nK

   IF Empty( cD ) .OR. nDepth > 32
      RETURN
   ENDIF
   cKids := _PS_DictGet( cD, "/Kids" )
   IF Empty( cKids )
      AAdd( aPages, n )
      RETURN
   ENDIF
   IF _PS_Ref( cKids ) > 0
      cKids := _PS_Obj( hPdf, _PS_Ref( cKids ) )
   ENDIF
   FOR EACH nK IN _PS_Refs( cKids )
      _PS_Pages( hPdf, nK, aPages, nDepth + 1 )
   NEXT

RETURN

/* /CropBox or /MediaBox of a page (inherited from /Parent too) */
STATIC FUNCTION _PS_Box( hPdf, n )

   LOCAL cD, cBox, nDepth := 0, a

   DO WHILE n > 0 .AND. nDepth++ < 32
      cD := _PS_Obj( hPdf, n )
      FOR EACH cBox IN { "/CropBox", "/MediaBox" }
         a := _PS_DictGet( cD, cBox )
         IF _PS_Ref( a ) > 0
            a := _PS_Obj( hPdf, _PS_Ref( a ) )
         ENDIF
         a := _PS_Nums( a )
         IF Len( a ) == 4
            RETURN { Min( a[ 1 ], a[ 3 ] ), Min( a[ 2 ], a[ 4 ] ), Max( a[ 1 ], a[ 3 ] ), Max( a[ 2 ], a[ 4 ] ) }
         ENDIF
      NEXT
      n := _PS_Ref( _PS_DictGet( cD, "/Parent" ) )
   ENDDO

RETURN { 0, 0, 595.28, 841.89 }                      // A4

/*---------------------------------------------------------------- the syntax */

STATIC FUNCTION _PS_IsWhite( cCh )
RETURN cCh $ " " + Chr( 9 ) + Chr( 10 ) + Chr( 12 ) + Chr( 13 ) + Chr( 0 ) .AND. ! cCh == ""

STATIC FUNCTION _PS_IsDelim( cCh )
RETURN cCh $ "()<>[]{}/%" .AND. ! cCh == ""

/* the next character that is not a white space or in a comment */
STATIC FUNCTION _PS_Skip( c, p )

   LOCAL nLen := hb_BLen( c ), cCh

   DO WHILE p <= nLen
      cCh := hb_BSubStr( c, p, 1 )
      IF cCh == "%"
         DO WHILE p <= nLen .AND. ! hb_BSubStr( c, p, 1 ) $ Chr( 10 ) + Chr( 13 )
            p++
         ENDDO
      ELSEIF _PS_IsWhite( cCh )
         p++
      ELSE
         EXIT
      ENDIF
   ENDDO

RETURN p

/* the next word (up to a white space or a delimiter) */
STATIC FUNCTION _PS_Token( c, p )

   LOCAL n

   p := _PS_Skip( c, p )
   n := p
   DO WHILE p <= hb_BLen( c ) .AND. ! _PS_IsWhite( hb_BSubStr( c, p, 1 ) ) .AND. ! _PS_IsDelim( hb_BSubStr( c, p, 1 ) )
      p++
   ENDDO

RETURN hb_BSubStr( c, n, p - n )

/* the position after the value that starts at p */
STATIC FUNCTION _PS_ValueEnd( c, p )

   LOCAL nLen := hb_BLen( c ), cCh := hb_BSubStr( c, p, 1 ), nDepth, q, cTok

   DO CASE
   CASE hb_BSubStr( c, p, 2 ) == "<<" .OR. cCh == "["
      nDepth := 0
      DO WHILE p <= nLen
         cCh := hb_BSubStr( c, p, 1 )
         DO CASE
         CASE cCh == "("
            p := _PS_StrEnd( c, p )
            LOOP
         CASE hb_BSubStr( c, p, 2 ) == "<<"
            nDepth++
            p += 2
            LOOP
         CASE hb_BSubStr( c, p, 2 ) == ">>"
            nDepth--
            p += 2
         CASE cCh == "<"
            p := hb_BAt( ">", c, p ) + 1
            LOOP
         CASE cCh == "["
            nDepth++
            p++
         CASE cCh == "]"
            nDepth--
            p++
         CASE cCh == "%"
            p := _PS_Skip( c, p )
            LOOP
         OTHERWISE
            p++
            LOOP
         ENDCASE
         IF nDepth == 0
            EXIT
         ENDIF
      ENDDO
      RETURN p
   CASE cCh == "("
      RETURN _PS_StrEnd( c, p )
   CASE cCh == "<"
      RETURN hb_BAt( ">", c, p ) + 1
   CASE cCh == "/"
      p++
      DO WHILE p <= nLen .AND. ! _PS_IsWhite( hb_BSubStr( c, p, 1 ) ) .AND. ! _PS_IsDelim( hb_BSubStr( c, p, 1 ) )
         p++
      ENDDO
      RETURN p
   ENDCASE
   /* a number, a keyword, or a reference "n g R" */
   cTok := _PS_Token( c, @p )
   IF IsDigit( Left( cTok, 1 ) )
      q := p
      cTok := _PS_Token( c, @q )
      IF ! Empty( cTok ) .AND. IsDigit( Left( cTok, 1 ) ) .AND. _PS_Token( c, @q ) == "R"
         RETURN q
      ENDIF
   ENDIF

RETURN p

/* the end of a string (...) with \ escapes and nested ( ) */
STATIC FUNCTION _PS_StrEnd( c, p )

   LOCAL nLen := hb_BLen( c ), nDepth := 0, cCh

   DO WHILE p <= nLen
      cCh := hb_BSubStr( c, p, 1 )
      DO CASE
      CASE cCh == "\"
         p += 2
         LOOP
      CASE cCh == "("
         nDepth++
      CASE cCh == ")"
         nDepth--
         IF nDepth == 0
            RETURN p + 1
         ENDIF
      ENDCASE
      p++
   ENDDO

RETURN p

/* the value of a key of a dictionary "<< ... >>" (its text), "" = no such key */
STATIC FUNCTION _PS_DictGet( cDict, cKey )

   LOCAL a := _PS_DictFind( cDict, cKey )

RETURN IIF( a == NIL, "", hb_BSubStr( cDict, a[ 2 ], a[ 3 ] - a[ 2 ] ) )

/* { nKeyStart, nValueStart, nValueEnd } of a key at the top level of a dictionary */
STATIC FUNCTION _PS_DictFind( cDict, cKey )

   LOCAL p, nLen := hb_BLen( cDict ), nKey, nV, nE, cName

   IF ! hb_BLeft( cDict, 2 ) == "<<"
      RETURN NIL
   ENDIF
   p := 3
   DO WHILE .T.
      p := _PS_Skip( cDict, p )
      IF p > nLen .OR. hb_BSubStr( cDict, p, 2 ) == ">>"
         EXIT
      ENDIF
      IF ! hb_BSubStr( cDict, p, 1 ) == "/"
         p := _PS_ValueEnd( cDict, p )             // something unexpected: over it
         LOOP
      ENDIF
      nKey := p
      p := _PS_ValueEnd( cDict, p )
      cName := hb_BSubStr( cDict, nKey, p - nKey )
      nV := _PS_Skip( cDict, p )
      nE := _PS_ValueEnd( cDict, nV )
      IF cName == cKey
         RETURN { nKey, nV, nE }
      ENDIF
      p := nE
   ENDDO

RETURN NIL

/* a dictionary with a key set (replaced or added) */
STATIC FUNCTION _PS_DictSet( cDict, cKey, cVal )

   LOCAL a := _PS_DictFind( cDict, cKey ), n

   IF a != NIL
      RETURN hb_BLeft( cDict, a[ 1 ] - 1 ) + cKey + " " + cVal + hb_BSubStr( cDict, a[ 3 ] )
   ENDIF
   n := hb_BRAt( ">>", cDict )

RETURN RTrim( hb_BLeft( cDict, n - 1 ) ) + " " + cKey + " " + cVal + " >>"

/* an array "[...]" (or "") with a reference added */
STATIC FUNCTION _PS_ArrAdd( cArr, n )

   LOCAL nEnd

   cArr := AllTrim( cArr )
   IF ! hb_BLeft( cArr, 1 ) == "["
      RETURN "[" + hb_ntos( n ) + " 0 R]"
   ENDIF
   nEnd := hb_BRAt( "]", cArr )

RETURN RTrim( hb_BLeft( cArr, nEnd - 1 ) ) + " " + hb_ntos( n ) + " 0 R]"

/* the object number of a reference "n g R", 0 = not a reference */
STATIC FUNCTION _PS_Ref( c )

   LOCAL p := 1, cN, cG

   c := AllTrim( c )
   cN := _PS_Token( c, @p )
   cG := _PS_Token( c, @p )
   IF ! Empty( cN ) .AND. IsDigit( cN ) .AND. ! Empty( cG ) .AND. IsDigit( cG ) .AND. _PS_Token( c, @p ) == "R"
      RETURN Val( cN )
   ENDIF

RETURN 0

/* the object numbers of the references in an array */
STATIC FUNCTION _PS_Refs( cArr )

   LOCAL a := {}, aTok := {}, p := 2, cTok, i

   DO WHILE p <= hb_BLen( cArr )
      cTok := _PS_Token( cArr, @p )
      IF Empty( cTok )
         p++
         LOOP
      ENDIF
      AAdd( aTok, cTok )
   ENDDO
   FOR i := 3 TO Len( aTok )
      IF aTok[ i ] == "R" .AND. IsDigit( aTok[ i - 2 ] )
         AAdd( a, Val( aTok[ i - 2 ] ) )
      ENDIF
   NEXT

RETURN a

/* the numbers of an array "[0 0 595 842]" */
STATIC FUNCTION _PS_Nums( cArr )

   LOCAL a := {}, cTok

   cArr := StrTran( StrTran( cArr, "[", " " ), "]", " " )
   FOR EACH cTok IN hb_ATokens( cArr )
      IF ! Empty( cTok )
         AAdd( a, Val( cTok ) )
      ENDIF
   NEXT

RETURN a

/*---------------------------------------------------------------- writing */

/* the objects, a new xref section (a table, or a stream when the PDF has xref streams) and the trailer */
STATIC FUNCTION _PS_Update( cAll, aObj, hPdf, nPrev, lStream, nSize )

   LOCAL cUpd := "", aOff := {}, a, nBase := hb_BLen( cAll ), cTr := hPdf[ "trailer" ], cX, nXref, i, nStart, nCount
   LOCAL aNums := {}, cIndex, cData, cExtra := "", nGen, k

   ASort( aObj,,, {| x, y | x[ 1 ] < y[ 1 ] } )
   FOR EACH a IN aObj
      nGen := IIF( hb_HHasKey( hPdf[ "xref" ], a[ 1 ] ) .AND. hPdf[ "xref" ][ a[ 1 ] ][ 1 ] == 1, hPdf[ "xref" ][ a[ 1 ] ][ 3 ], 0 )
      AAdd( aOff, { a[ 1 ], nBase + hb_BLen( cUpd ), nGen } )
      cUpd += hb_ntos( a[ 1 ] ) + " " + hb_ntos( nGen ) + " obj" + Chr( 10 ) + a[ 2 ] + Chr( 10 ) + "endobj" + Chr( 10 )
   NEXT
   FOR EACH k IN { "/Info", "/ID" }
      IF ! Empty( _PS_DictGet( cTr, k ) )
         cExtra += " " + k + " " + _PS_DictGet( cTr, k )
      ENDIF
   NEXT
   nXref := nBase + hb_BLen( cUpd )

   IF ! lStream
      cX := "xref" + Chr( 10 )
      i := 1
      DO WHILE i <= Len( aOff )
         nStart := i
         DO WHILE i < Len( aOff ) .AND. aOff[ i + 1 ][ 1 ] == aOff[ i ][ 1 ] + 1
            i++
         ENDDO
         cX += hb_ntos( aOff[ nStart ][ 1 ] ) + " " + hb_ntos( i - nStart + 1 ) + Chr( 10 )
         FOR nCount := nStart TO i
            cX += StrZero( aOff[ nCount ][ 2 ], 10 ) + " " + StrZero( aOff[ nCount ][ 3 ], 5 ) + " n" + Chr( 13 ) + Chr( 10 )
         NEXT
         i++
      ENDDO
      cX += "trailer" + Chr( 10 ) + "<< /Size " + hb_ntos( nSize ) + " /Root " + _PS_DictGet( cTr, "/Root" ) + ;
            " /Prev " + hb_ntos( nPrev ) + cExtra + " >>" + Chr( 10 )
   ELSE
      /* an xref stream: the entries of the objects and of itself, /W [1 4 2], not compressed */
      AAdd( aOff, { nSize, nXref, 0 } )
      cData := ""
      cIndex := ""
      FOR EACH a IN aOff
         AAdd( aNums, a[ 1 ] )
         cIndex += hb_ntos( a[ 1 ] ) + " 1 "
         cData += hb_BChar( 1 ) + _PS_BEStr( a[ 2 ], 4 ) + _PS_BEStr( a[ 3 ], 2 )
      NEXT
      cX := hb_ntos( nSize ) + " 0 obj" + Chr( 10 ) + "<< /Type /XRef /Size " + hb_ntos( nSize + 1 ) + ;
            " /Root " + _PS_DictGet( cTr, "/Root" ) + " /Prev " + hb_ntos( nPrev ) + cExtra + ;
            " /W [1 4 2] /Index [" + RTrim( cIndex ) + "] /Length " + hb_ntos( hb_BLen( cData ) ) + " >>" + Chr( 10 ) + ;
            "stream" + Chr( 10 ) + cData + Chr( 10 ) + "endstream" + Chr( 10 ) + "endobj" + Chr( 10 )
   ENDIF

RETURN cUpd + cX + "startxref" + Chr( 10 ) + hb_ntos( nXref ) + Chr( 10 ) + "%%EOF" + Chr( 10 )

STATIC FUNCTION _PS_BEStr( n, nLen )

   LOCAL c := "", i

   FOR i := 1 TO nLen
      c := hb_BChar( n % 256 ) + c
      n := Int( n / 256 )
   NEXT

RETURN c

/* the appearance of the signature: a frame and the lines of text */
STATIC FUNCTION _PS_Appearance( aLines, nW, nH, nFs, lBorder, lBack, nTx, cImgOps )

   LOCAL c := "", cLine, nY, nLead := nFs * 1.2

   IF nW <= 0
      RETURN ""
   ENDIF
   IF lBack
      c += "q 1 g 0 0 " + _PS_N( nW ) + " " + _PS_N( nH ) + " re f Q" + Chr( 10 )
   ENDIF
   c += hb_defaultValue( cImgOps, "" )
   IF lBorder
      c += "q 0.6 w 0.25 0.25 0.25 RG 0.5 0.5 " + _PS_N( nW - 1 ) + " " + _PS_N( nH - 1 ) + " re S Q" + Chr( 10 )
   ENDIF
   nY := nH - 2 - nFs
   c += "BT /F1 " + _PS_N( nFs ) + " Tf 0 g " + _PS_N( nLead ) + " TL " + _PS_N( hb_defaultValue( nTx, 3 ) ) + " " + _PS_N( nY ) + " Td" + Chr( 10 )
   FOR EACH cLine IN aLines
      c += IIF( cLine:__enumIndex() == 1, "", "T* " ) + "(" + _PS_WinAnsi( cLine ) + ") Tj" + Chr( 10 )
   NEXT
   c += "ET"

RETURN c

/* the picture of the signature: a JPEG or PNG file -> { "w", "h", "dict" (ColorSpace,
   BitsPerComponent, Filter ...), "data" (the stream), "smask" (PNG alpha, Flate, or NIL) };
   NIL and cErr when it cannot be used */
STATIC FUNCTION _PS_Image( cFile, cErr )

   LOCAL c := hb_MemoRead( cFile )

   IF hb_BLen( c ) < 24
      cErr := "Image not found or empty: " + cFile
      RETURN NIL
   ENDIF
   IF hb_BPeek( c, 1 ) == 0xFF .AND. hb_BPeek( c, 2 ) == 0xD8
      RETURN _PS_Jpeg( c, cFile, @cErr )
   ENDIF
   IF hb_BPeek( c, 1 ) == 0x89 .AND. hb_BSubStr( c, 2, 3 ) == "PNG"
      RETURN _PS_Png( c, cFile, @cErr )
   ENDIF
   cErr := "The image must be JPEG or PNG: " + cFile

RETURN NIL

/* JPEG goes into the PDF as it is (DCTDecode): the size and colors from its SOF marker */
STATIC FUNCTION _PS_Jpeg( c, cFile, cErr )

   LOCAL p := 3, nM, nLen := hb_BLen( c ), nComp, cCs

   DO WHILE p + 9 <= nLen .AND. hb_BPeek( c, p ) == 0xFF
      nM := hb_BPeek( c, p + 1 )
      IF nM == 0xFF                     /* fill byte */
         p++
         LOOP
      ENDIF
      IF nM >= 0xC0 .AND. nM <= 0xCF .AND. nM != 0xC4 .AND. nM != 0xC8 .AND. nM != 0xCC
         nComp := hb_BPeek( c, p + 9 )
         DO CASE
         CASE nComp == 1 ; cCs := "/ColorSpace /DeviceGray"
         CASE nComp == 3 ; cCs := "/ColorSpace /DeviceRGB"
         CASE nComp == 4 ; cCs := "/ColorSpace /DeviceCMYK /Decode [1 0 1 0 1 0 1 0]"   /* Adobe CMYK */
         OTHERWISE
            EXIT
         ENDCASE
         RETURN { "w" => _PS_BE( c, p + 7, 2 ), "h" => _PS_BE( c, p + 5, 2 ), ;
                  "dict" => cCs + " /BitsPerComponent 8 /Filter /DCTDecode", "data" => c, "smask" => NIL }
      ENDIF
      p += 2 + _PS_BE( c, p + 2, 2 )
   ENDDO
   cErr := "JPEG not understood: " + cFile

RETURN NIL

/* PNG: gray, RGB and palette go in with their own compression (Flate with the PNG
   predictor); with alpha (gray + alpha, RGBA) the pixels are unpacked and the alpha
   becomes the soft mask. 8 bits (palette and gray also 1, 2, 4), not interlaced. */
STATIC FUNCTION _PS_Png( c, cFile, cErr )

   LOCAL p := 9, nLen := hb_BLen( c ), nCl, cType, nW := 0, nH := 0, nBits := 0, nCt := -1, nLace := 0
   LOCAL cIdat := "", cPlte := "", nColors, cRaw, cPix, cAlpha, nBpp, nRow, nX, cCs, nPix

   DO WHILE p + 8 <= nLen
      nCl := _PS_BE( c, p, 4 )
      cType := hb_BSubStr( c, p + 4, 4 )
      IF cType == "IHDR"
         nW := _PS_BE( c, p + 8, 4 )
         nH := _PS_BE( c, p + 12, 4 )
         nBits := hb_BPeek( c, p + 16 )
         nCt := hb_BPeek( c, p + 17 )
         nLace := hb_BPeek( c, p + 20 )
      ELSEIF cType == "PLTE"
         cPlte := hb_BSubStr( c, p + 8, nCl )
      ELSEIF cType == "IDAT"
         cIdat += hb_BSubStr( c, p + 8, nCl )
      ELSEIF cType == "IEND"
         EXIT
      ENDIF
      p += 12 + nCl
   ENDDO
   IF nW <= 0 .OR. nH <= 0 .OR. Empty( cIdat ) .OR. nLace != 0 .OR. ;
      hb_AScan( { 0, 2, 3, 4, 6 }, nCt ) == 0 .OR. nBits > 8 .OR. ( nBits != 8 .AND. ! ( nCt == 0 .OR. nCt == 3 ) )
      cErr := "PNG not supported (8 bits, not interlaced): " + cFile
      RETURN NIL
   ENDIF

   IF nCt == 0 .OR. nCt == 2 .OR. nCt == 3
      nColors := IIF( nCt == 2, 3, 1 )
      DO CASE
      CASE nCt == 0 ; cCs := "/ColorSpace /DeviceGray"
      CASE nCt == 2 ; cCs := "/ColorSpace /DeviceRGB"
      OTHERWISE
         IF Empty( cPlte )
            cErr := "PNG without a palette: " + cFile
            RETURN NIL
         ENDIF
         cCs := "/ColorSpace [/Indexed /DeviceRGB " + hb_ntos( Int( hb_BLen( cPlte ) / 3 ) - 1 ) + " <" + hb_StrToHex( cPlte ) + ">]"
      ENDCASE
      RETURN { "w" => nW, "h" => nH, "data" => cIdat, "smask" => NIL, ;
               "dict" => cCs + " /BitsPerComponent " + hb_ntos( nBits ) + " /Filter /FlateDecode" + ;
                         " /DecodeParms << /Predictor 15 /Colors " + hb_ntos( nColors ) + ;
                         " /BitsPerComponent " + hb_ntos( nBits ) + " /Columns " + hb_ntos( nW ) + " >>" }
   ENDIF

   /* with alpha: unfilter the rows, then the colors and the alpha apart */
   nBpp := IIF( nCt == 6, 4, 2 )
   cRaw := hb_ZUncompress( cIdat, nH * ( 1 + nW * nBpp ) )
   IF ! HB_ISSTRING( cRaw ) .OR. hb_BLen( cRaw ) < nH * ( 1 + nW * nBpp )
      cErr := "PNG data damaged: " + cFile
      RETURN NIL
   ENDIF
   cRaw := _PS_PngUnfilter( cRaw, nW * nBpp, nBpp, nH )
   cPix := Replicate( Chr( 0 ), nW * nH * ( nBpp - 1 ) )
   cAlpha := Replicate( Chr( 0 ), nW * nH )
   FOR nRow := 0 TO nH - 1
      FOR nX := 0 TO nW - 1
         nPix := nRow * nW + nX
         p := nPix * nBpp + 1
         IF nBpp == 4
            hb_BPoke( @cPix, nPix * 3 + 1, hb_BPeek( cRaw, p ) )
            hb_BPoke( @cPix, nPix * 3 + 2, hb_BPeek( cRaw, p + 1 ) )
            hb_BPoke( @cPix, nPix * 3 + 3, hb_BPeek( cRaw, p + 2 ) )
         ELSE
            hb_BPoke( @cPix, nPix + 1, hb_BPeek( cRaw, p ) )
         ENDIF
         hb_BPoke( @cAlpha, nPix + 1, hb_BPeek( cRaw, p + nBpp - 1 ) )
      NEXT
   NEXT

RETURN { "w" => nW, "h" => nH, "data" => hb_ZCompress( cPix ), "smask" => hb_ZCompress( cAlpha ), ;
         "dict" => IIF( nBpp == 4, "/ColorSpace /DeviceRGB", "/ColorSpace /DeviceGray" ) + ;
                   " /BitsPerComponent 8 /Filter /FlateDecode" }

/* PNG rows without their filter bytes, unfiltered (None, Sub, Up, Average, Paeth) */
STATIC FUNCTION _PS_PngUnfilter( cRaw, nRowLen, nBpp, nRows )

   LOCAL cOut := Replicate( Chr( 0 ), nRowLen * nRows ), nRow, i, nF, nA, nB, nC, nV, nIn, nOut, nP, pa, pb, pc

   FOR nRow := 0 TO nRows - 1
      nIn := nRow * ( nRowLen + 1 ) + 1
      nF := hb_BPeek( cRaw, nIn )
      nOut := nRow * nRowLen
      FOR i := 1 TO nRowLen
         nV := hb_BPeek( cRaw, nIn + i )
         nA := IIF( i > nBpp, hb_BPeek( cOut, nOut + i - nBpp ), 0 )
         nB := IIF( nRow > 0, hb_BPeek( cOut, nOut - nRowLen + i ), 0 )
         nC := IIF( nRow > 0 .AND. i > nBpp, hb_BPeek( cOut, nOut - nRowLen + i - nBpp ), 0 )
         SWITCH nF
         CASE 1
            nV += nA
            EXIT
         CASE 2
            nV += nB
            EXIT
         CASE 3
            nV += Int( ( nA + nB ) / 2 )
            EXIT
         CASE 4
            nP := nA + nB - nC
            pa := Abs( nP - nA )
            pb := Abs( nP - nB )
            pc := Abs( nP - nC )
            nV += IIF( pa <= pb .AND. pa <= pc, nA, IIF( pb <= pc, nB, nC ) )
            EXIT
         ENDSWITCH
         hb_BPoke( @cOut, nOut + i, nV % 256 )
      NEXT
   NEXT

RETURN cOut

/* a number for PDF: at most 2 decimals, a dot */
STATIC FUNCTION _PS_N( n )
RETURN hb_ntos( Round( n, 2 ) )

/* a text string: UTF-16BE in hex, any letters */
STATIC FUNCTION _PS_Text( c )

   LOCAL cHex := "<FEFF", i, n

   IF ! hb_StrIsUTF8( c )
      c := hb_StrToUTF8( c )
   ENDIF
   FOR i := 1 TO hb_UTF8Len( c )
      n := hb_UTF8Peek( c, i )
      IF n > 0xFFFF
         n -= 0x10000
         cHex += hb_NumToHex( 0xD800 + Int( n / 1024 ), 4 ) + hb_NumToHex( 0xDC00 + n % 1024, 4 )
      ELSE
         cHex += hb_NumToHex( n, 4 )
      ENDIF
   NEXT

RETURN cHex + ">"

/* text for a content stream with Helvetica /WinAnsiEncoding: the bytes of Windows-1252, ( ) \ escaped */
STATIC FUNCTION _PS_WinAnsi( c )

   LOCAL cOut := "", i, n, nB, aMap := { ;
      { 0x20AC, 0x80 }, { 0x201A, 0x82 }, { 0x0192, 0x83 }, { 0x201E, 0x84 }, { 0x2026, 0x85 }, { 0x2020, 0x86 }, ;
      { 0x2021, 0x87 }, { 0x02C6, 0x88 }, { 0x2030, 0x89 }, { 0x0160, 0x8A }, { 0x2039, 0x8B }, { 0x0152, 0x8C }, ;
      { 0x017D, 0x8E }, { 0x2018, 0x91 }, { 0x2019, 0x92 }, { 0x201C, 0x93 }, { 0x201D, 0x94 }, { 0x2022, 0x95 }, ;
      { 0x2013, 0x96 }, { 0x2014, 0x97 }, { 0x02DC, 0x98 }, { 0x2122, 0x99 }, { 0x0161, 0x9A }, { 0x203A, 0x9B }, ;
      { 0x0153, 0x9C }, { 0x017E, 0x9E }, { 0x0178, 0x9F }, ;
      { 0x010C, 0x81 }, { 0x010D, 0x8D }, { 0x0106, 0x8F }, { 0x0107, 0x90 }, ;    // C c with caron / acute,
      { 0x0110, 0x9D }, { 0x0111, 0x7F } }, k                                    // D d with stroke: /Differences

   IF ! hb_StrIsUTF8( c )
      c := hb_StrToUTF8( c )
   ENDIF
   FOR i := 1 TO hb_UTF8Len( c )
      n := hb_UTF8Peek( c, i )
      DO CASE
      CASE n >= 32 .AND. n < 127
         nB := n
      CASE n >= 0xA0 .AND. n <= 0xFF
         nB := n
      OTHERWISE
         k := AScan( aMap, {| x | x[ 1 ] == n } )
         nB := IIF( k > 0, aMap[ k ][ 2 ], Asc( "?" ) )
      ENDCASE
      IF nB == 40 .OR. nB == 41 .OR. nB == 92                 // ( ) \
         cOut += "\"
      ENDIF
      cOut += hb_BChar( nB )
   NEXT

RETURN cOut

/* D:YYYYMMDDHHmmSS+HH'mm' */
STATIC FUNCTION _PS_Date( t )

   LOCAL nOff := Int( hb_UTCOffset() / 60 ), cSign := IIF( nOff < 0, "-", "+" )

   nOff := Abs( nOff )

RETURN "(D:" + Left( hb_TToS( t ), 14 ) + cSign + StrZero( Int( nOff / 60 ), 2 ) + "'" + StrZero( nOff % 60, 2 ) + "')"
