/*
 * PDF digital signature - Windows CryptoAPI part of PDFSign.prg
 *
 * Copyright 2026 Srđan Dragojlović <digikv@yahoo.com>
 * Company  S.O.K. doo Kraljevo
 * www - https://sokdoo.com
 *
 * Dual licensed: GNU GPL version 3 or later (COPYING), or a commercial
 * license from the author - see LICENSE.
 *
 * Sertifikati iz Windows prodavnice "MY" (licni: A1 instaliran, A3 na
 * kartici / tokenu - CSP ili CNG kljuc) ili iz .pfx fajla (kljuc se ne
 * instalira). Potpis: CMS / PKCS#7 detached, SHA-256, signingTime, lanac
 * sertifikata - ono sto PDF trazi za /SubFilter /adbe.pkcs7.detached.
 *
 *   PDFS_CERTS()                          -> { { cThumb, cName, cIssuer, cValidTo, lKey }, ... }
 *   PDFS_SELECTCERT( cTitle, cText )      -> cThumb, "" = odustao (Windows dijalog)
 *   PDFS_CERTINFO( cThumb, cPfx, cPass, @cErr ) -> { cName, cSubject, cIssuer, cValidTo, cSerial } / NIL
 *   PDFS_SIGN( cData, cThumb, cPfx, cPass, @cErr ) -> cDer / ""
 *
 * Linkuje se sa crypt32 (hbmk2: -lcrypt32; pdfsign.hbc).
 */

#include "hbapi.h"
#include "hbapiitm.h"
#include "hbapifs.h"

#if defined( HB_OS_WIN )

/* old headers hide CertGetNameString, PFXImportCertStore... below Windows 2000/XP */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT  0x0501
#endif
#define CMSG_SIGNER_ENCODE_INFO_HAS_CMS_FIELDS
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <windows.h>
#include <wincrypt.h>

/* Compatibility with old Platform SDK headers (Borland bcc32 5.8 / C++Builder 2006-2007,
   old MinGW): what is missing there is defined here. With a current SDK nothing changes. */

/* handle of a key: HCRYPTPROV (CAPI) or NCRYPT_KEY_HANDLE (CNG), both of the size of a pointer (HCRYPTPROV exists in every header).
   Own type, because HCRYPTPROV_OR_NCRYPT_KEY_HANDLE does not exist in old headers */
typedef HCRYPTPROV PDFS_KEYHANDLE;

#ifndef CERT_NCRYPT_KEY_SPEC
#define CERT_NCRYPT_KEY_SPEC  0xFFFFFFFF
#endif
#ifndef szOID_NIST_sha256
#define szOID_NIST_sha256  "2.16.840.1.101.3.4.2.1"
#endif
#ifndef CRYPT_ACQUIRE_CACHE_FLAG
#define CRYPT_ACQUIRE_CACHE_FLAG  0x00000001
#endif
#ifndef CERT_NAME_SIMPLE_DISPLAY_TYPE
#define CERT_NAME_SIMPLE_DISPLAY_TYPE  4
#endif
#ifndef CERT_NAME_RDN_TYPE
#define CERT_NAME_RDN_TYPE  2
#endif
#ifndef CERT_NAME_ISSUER_FLAG
#define CERT_NAME_ISSUER_FLAG  0x1
#endif
#ifndef CERT_X500_NAME_STR
#define CERT_X500_NAME_STR  3
#endif
#ifndef CRYPT_SILENT
#define CRYPT_SILENT  0x00000040
#endif

#ifndef PKCS12_NO_PERSIST_KEY
#define PKCS12_NO_PERSIST_KEY  0x00008000
#endif
#ifndef CRYPT_ACQUIRE_ALLOW_NCRYPT_KEY_FLAG
#define CRYPT_ACQUIRE_ALLOW_NCRYPT_KEY_FLAG  0x00010000
#endif
#ifndef CRYPT_ACQUIRE_PREFER_NCRYPT_KEY_FLAG
#define CRYPT_ACQUIRE_PREFER_NCRYPT_KEY_FLAG  0x00020000
#endif
#ifndef PKCS12_ALWAYS_CNG_KSP
#define PKCS12_ALWAYS_CNG_KSP  0x00000200
#endif
#ifndef PKCS12_PREFER_CNG_KSP
#define PKCS12_PREFER_CNG_KSP  0x00000100
#endif
#ifndef PROV_RSA_AES
#define PROV_RSA_AES  24
#endif

#define ENC_TYPE  ( X509_ASN_ENCODING | PKCS_7_ASN_ENCODING )

/* UTF-8 <-> UTF-16 */
static LPWSTR s_wide( const char * sz )
{
   int n = MultiByteToWideChar( CP_UTF8, 0, sz ? sz : "", -1, NULL, 0 );
   LPWSTR w = ( LPWSTR ) hb_xgrab( ( n + 1 ) * sizeof( WCHAR ) );
   MultiByteToWideChar( CP_UTF8, 0, sz ? sz : "", -1, w, n );
   return w;
}

static void s_retUtf8( PHB_ITEM pArr, HB_SIZE nIdx, LPCWSTR w )
{
   int n = WideCharToMultiByte( CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL );
   char * s = ( char * ) hb_xgrab( n + 1 );
   WideCharToMultiByte( CP_UTF8, 0, w, -1, s, n, NULL, NULL );
   hb_arraySetC( pArr, nIdx, s );
   hb_xfree( s );
}

/* the name of a certificate: CERT_NAME_SIMPLE_DISPLAY (CN), the issuer's, the whole subject */
static void s_certName( PCCERT_CONTEXT pCert, DWORD dwType, DWORD dwFlags, PHB_ITEM pArr, HB_SIZE nIdx )
{
   WCHAR buf[ 1024 ];
   DWORD dwStr = CERT_X500_NAME_STR;
   buf[ 0 ] = 0;
   CertGetNameStringW( pCert, dwType, dwFlags, dwType == CERT_NAME_RDN_TYPE ? ( void * ) &dwStr : NULL,
                       buf, sizeof( buf ) / sizeof( WCHAR ) );
   s_retUtf8( pArr, nIdx, buf );
}

static void s_fileTime( const FILETIME * pft, PHB_ITEM pArr, HB_SIZE nIdx )
{
   SYSTEMTIME st;
   char sz[ 20 ];
   FileTimeToSystemTime( pft, &st );
   hb_snprintf( sz, sizeof( sz ), "%04d%02d%02d", st.wYear, st.wMonth, st.wDay );
   hb_arraySetC( pArr, nIdx, sz );
}

static void s_thumb( PCCERT_CONTEXT pCert, char * szHex )
{
   BYTE hash[ 20 ];
   DWORD cb = sizeof( hash ), i;
   szHex[ 0 ] = 0;
   if( CertGetCertificateContextProperty( pCert, CERT_HASH_PROP_ID, hash, &cb ) )
   {
      for( i = 0; i < cb; i++ )
         hb_snprintf( szHex + i * 2, 3, "%02X", hash[ i ] );
   }
}

static HB_BOOL s_hasKey( PCCERT_CONTEXT pCert )
{
   DWORD cb = 0;
   return CertGetCertificateContextProperty( pCert, CERT_KEY_PROV_INFO_PROP_ID, NULL, &cb ) ||
          CertGetCertificateContextProperty( pCert, CERT_KEY_CONTEXT_PROP_ID, NULL, &cb );
}

/* the certificate: from the .pfx (first one with a key) or from the store MY by its thumbprint */
static PCCERT_CONTEXT s_getCert( const char * szThumb, const char * szPfx, const char * szPass,
                                 HCERTSTORE * phStore, char * szErr, int nErr )
{
   PCCERT_CONTEXT pCert = NULL;
   *phStore = NULL;
   if( szPfx && *szPfx )
   {
      HB_FHANDLE hFile;
      HB_SIZE nSize;
      BYTE * pBuf;
      CRYPT_DATA_BLOB blob;
      LPWSTR wPass;

      hFile = hb_fsOpen( szPfx, FO_READ | FO_SHARED );
      if( hFile == FS_ERROR )
      {
         hb_snprintf( szErr, nErr, "Cannot read %s", szPfx );
         return NULL;
      }
      nSize = ( HB_SIZE ) hb_fsSeek( hFile, 0, FS_END );
      hb_fsSeek( hFile, 0, FS_SET );
      pBuf = ( BYTE * ) hb_xgrab( nSize + 1 );
      nSize = hb_fsReadLarge( hFile, pBuf, nSize );
      hb_fsClose( hFile );
      blob.cbData = ( DWORD ) nSize;
      blob.pbData = pBuf;
      wPass = s_wide( szPass );
      /* the key in CNG (SHA-256), only in memory; older Windows: what it can */
      *phStore = PFXImportCertStore( &blob, wPass, PKCS12_NO_PERSIST_KEY | PKCS12_ALWAYS_CNG_KSP );
      if( ! *phStore )
         *phStore = PFXImportCertStore( &blob, wPass, PKCS12_PREFER_CNG_KSP );
      if( ! *phStore )
         *phStore = PFXImportCertStore( &blob, wPass, 0 );
      hb_xfree( wPass );
      hb_xfree( pBuf );
      if( ! *phStore )
      {
         hb_snprintf( szErr, nErr, "Cannot open %s (wrong password?) - error 0x%08lX", szPfx, ( unsigned long ) GetLastError() );
         return NULL;
      }
      while( ( pCert = CertEnumCertificatesInStore( *phStore, pCert ) ) != NULL )
      {
         if( s_hasKey( pCert ) )
            return pCert;
      }
      hb_snprintf( szErr, nErr, "%s has no certificate with a private key", szPfx );
      return NULL;
   }

   *phStore = CertOpenStore( CERT_STORE_PROV_SYSTEM_W, 0, 0, CERT_SYSTEM_STORE_CURRENT_USER | CERT_STORE_READONLY_FLAG, L"MY" );
   if( ! *phStore )
   {
      hb_snprintf( szErr, nErr, "Cannot open the certificate store" );
      return NULL;
   }
   if( szThumb && *szThumb )
   {
      BYTE hash[ 64 ];
      DWORD n = 0;
      CRYPT_HASH_BLOB hb;
      const char * p = szThumb;
      while( *p && n < sizeof( hash ) )
      {
         unsigned int v;
         if( *p == ' ' || *p == ':' ) { p++; continue; }
         if( ! p[ 1 ] || sscanf( p, "%2x", &v ) != 1 )
            break;
         hash[ n++ ] = ( BYTE ) v;
         p += 2;
      }
      hb.cbData = n;
      hb.pbData = hash;
      pCert = CertFindCertificateInStore( *phStore, ENC_TYPE, 0, CERT_FIND_HASH, &hb, NULL );
   }
   if( ! pCert )
      hb_snprintf( szErr, nErr, "Certificate not found: %s", szThumb ? szThumb : "" );
   return pCert;
}

/* the private key of a certificate. CNG when it can be (A3 tokens with a KSP, keys of
   .pfx files); a CAPI key of a Microsoft software provider (Base / Strong / Enhanced,
   PROV_RSA_FULL: no SHA-256, error NTE_BAD_TYPE) is opened again in the same container
   of the "Enhanced RSA and AES" provider, which has SHA-256 (*phAes: to release) */
static HB_BOOL s_getKey( PCCERT_CONTEXT pCert, PDFS_KEYHANDLE * phKey, DWORD * pdwKeySpec, HCRYPTPROV * phAes )
{
   BOOL fFree = FALSE;
   DWORD cb = 0;

   *phAes = 0;
   if( ! CryptAcquireCertificatePrivateKey( pCert, CRYPT_ACQUIRE_PREFER_NCRYPT_KEY_FLAG | CRYPT_ACQUIRE_CACHE_FLAG,
                                            NULL, ( void * ) phKey, pdwKeySpec, &fFree ) )
      return HB_FALSE;
   if( *pdwKeySpec != CERT_NCRYPT_KEY_SPEC &&
       CertGetCertificateContextProperty( pCert, CERT_KEY_PROV_INFO_PROP_ID, NULL, &cb ) && cb > 0 )
   {
      CRYPT_KEY_PROV_INFO * pInfo = ( CRYPT_KEY_PROV_INFO * ) hb_xgrab( cb );
      if( CertGetCertificateContextProperty( pCert, CERT_KEY_PROV_INFO_PROP_ID, pInfo, &cb ) &&
          pInfo->dwProvType == PROV_RSA_FULL && pInfo->pwszProvName &&
          wcsstr( pInfo->pwszProvName, L"Microsoft" ) && ! wcsstr( pInfo->pwszProvName, L"Smart Card" ) )
      {
         HCRYPTPROV hProv = 0;
         if( CryptAcquireContextW( &hProv, pInfo->pwszContainerName, L"Microsoft Enhanced RSA and AES Cryptographic Provider",
                                   PROV_RSA_AES, pInfo->dwFlags & ( CRYPT_MACHINE_KEYSET | CRYPT_SILENT ) ) )
         {
            *phAes = hProv;
            *phKey = hProv;
            *pdwKeySpec = pInfo->dwKeySpec;
         }
      }
      hb_xfree( pInfo );
   }
   return HB_TRUE;
}

/* PDFS_CERTS() -> the personal certificates of the user */
HB_FUNC( PDFS_CERTS )
{
   PHB_ITEM pRet = hb_itemArrayNew( 0 );
   HCERTSTORE hStore = CertOpenStore( CERT_STORE_PROV_SYSTEM_W, 0, 0, CERT_SYSTEM_STORE_CURRENT_USER | CERT_STORE_READONLY_FLAG, L"MY" );

   if( hStore )
   {
      PCCERT_CONTEXT pCert = NULL;
      while( ( pCert = CertEnumCertificatesInStore( hStore, pCert ) ) != NULL )
      {
         PHB_ITEM pItem = hb_itemArrayNew( 5 );
         char szHex[ 41 ];
         s_thumb( pCert, szHex );
         hb_arraySetC( pItem, 1, szHex );
         s_certName( pCert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, pItem, 2 );
         s_certName( pCert, CERT_NAME_SIMPLE_DISPLAY_TYPE, CERT_NAME_ISSUER_FLAG, pItem, 3 );
         s_fileTime( &pCert->pCertInfo->NotAfter, pItem, 4 );
         hb_arraySetL( pItem, 5, s_hasKey( pCert ) );
         hb_arrayAddForward( pRet, pItem );
         hb_itemRelease( pItem );
      }
      CertCloseStore( hStore, 0 );
   }
   hb_itemReturnRelease( pRet );
}

/* PDFS_SELECTCERT( cTitle, cText ) -> thumbprint of the certificate the user chose, "" = cancelled */
typedef PCCERT_CONTEXT ( WINAPI * PDFS_PSELECTCERT )( HCERTSTORE, HWND, LPCWSTR, LPCWSTR, DWORD, DWORD, void * );

HB_FUNC( PDFS_SELECTCERT )
{
   HMODULE hLib = LoadLibraryW( L"cryptui.dll" );
   char szHex[ 41 ];
   szHex[ 0 ] = 0;
   if( hLib )
   {
      PDFS_PSELECTCERT pSelect = ( PDFS_PSELECTCERT ) ( void * ) GetProcAddress( hLib, "CryptUIDlgSelectCertificateFromStore" );
      HCERTSTORE hStore = CertOpenStore( CERT_STORE_PROV_SYSTEM_W, 0, 0, CERT_SYSTEM_STORE_CURRENT_USER | CERT_STORE_READONLY_FLAG, L"MY" );
      if( pSelect && hStore )
      {
         LPWSTR wTitle = s_wide( hb_parc( 1 ) ? hb_parc( 1 ) : "Certificate" );
         LPWSTR wText = s_wide( hb_parc( 2 ) ? hb_parc( 2 ) : "Choose the certificate to sign with" );
         PCCERT_CONTEXT pCert = pSelect( hStore, GetActiveWindow(), wTitle, wText, 0, 0, NULL );
         if( pCert )
         {
            s_thumb( pCert, szHex );
            CertFreeCertificateContext( pCert );
         }
         hb_xfree( wTitle );
         hb_xfree( wText );
      }
      if( hStore )
         CertCloseStore( hStore, 0 );
      FreeLibrary( hLib );
   }
   hb_retc( szHex );
}

/* PDFS_CERTINFO( cThumb, cPfx, cPass, @cErr ) -> { cName, cSubject, cIssuer, cValidTo, cSerial } / NIL */
HB_FUNC( PDFS_CERTINFO )
{
   HCERTSTORE hStore;
   char szErr[ 512 ];
   PCCERT_CONTEXT pCert;

   szErr[ 0 ] = 0;
   pCert = s_getCert( hb_parc( 1 ), hb_parc( 2 ), hb_parc( 3 ), &hStore, szErr, sizeof( szErr ) );
   if( pCert )
   {
      PHB_ITEM pRet = hb_itemArrayNew( 5 );
      char szSer[ 200 ];
      DWORD i, n = pCert->pCertInfo->SerialNumber.cbData;
      s_certName( pCert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, pRet, 1 );
      s_certName( pCert, CERT_NAME_RDN_TYPE, 0, pRet, 2 );
      s_certName( pCert, CERT_NAME_SIMPLE_DISPLAY_TYPE, CERT_NAME_ISSUER_FLAG, pRet, 3 );
      s_fileTime( &pCert->pCertInfo->NotAfter, pRet, 4 );
      szSer[ 0 ] = 0;
      for( i = 0; i < n && i < 90; i++ )                 /* little endian in CryptoAPI */
         hb_snprintf( szSer + i * 2, 3, "%02X", pCert->pCertInfo->SerialNumber.pbData[ n - 1 - i ] );
      hb_arraySetC( pRet, 5, szSer );
      CertFreeCertificateContext( pCert );
      hb_itemReturnRelease( pRet );
   }
   else
      hb_ret();
   if( hStore )
      CertCloseStore( hStore, 0 );
   hb_storc( szErr, 4 );
}

/* PDFS_SIGN( cData, cThumb, cPfx, cPass, @cErr ) -> the DER of a detached CMS signature of cData */
HB_FUNC( PDFS_SIGN )
{
   HCERTSTORE hStore;
   char szErr[ 512 ];
   PCCERT_CONTEXT pCert;
   BYTE * pOut = NULL;
   DWORD cbOut = 0;

   szErr[ 0 ] = 0;
   pCert = s_getCert( hb_parc( 2 ), hb_parc( 3 ), hb_parc( 4 ), &hStore, szErr, sizeof( szErr ) );
   if( pCert )
   {
      PDFS_KEYHANDLE hKey = 0;
      DWORD dwKeySpec = 0;
      HCRYPTPROV hAes = 0;

      if( ! s_getKey( pCert, &hKey, &dwKeySpec, &hAes ) )
         hb_snprintf( szErr, sizeof( szErr ), "No access to the private key (token / card, PIN?) - error 0x%08lX",
                      ( unsigned long ) GetLastError() );
      else
      {
         CMSG_SIGNER_ENCODE_INFO si;
         CMSG_SIGNED_ENCODE_INFO sei;
         CRYPT_ATTRIBUTE attr;
         CRYPT_ATTR_BLOB attrBlob;
         BYTE timeBuf[ 64 ];
         DWORD cbTime = sizeof( timeBuf );
         FILETIME ft;
         PCCERT_CHAIN_CONTEXT pChain = NULL;
         CERT_CHAIN_PARA chainPara;
         CERT_BLOB certs[ 16 ];
         DWORD nCerts = 0;
         HCRYPTMSG hMsg;

         /* signingTime */
         GetSystemTimeAsFileTime( &ft );
         CryptEncodeObject( X509_ASN_ENCODING, szOID_RSA_signingTime, &ft, timeBuf, &cbTime );
         attrBlob.cbData = cbTime;
         attrBlob.pbData = timeBuf;
         attr.pszObjId = ( LPSTR ) szOID_RSA_signingTime;
         attr.cValue = 1;
         attr.rgValue = &attrBlob;

         memset( &si, 0, sizeof( si ) );
         si.cbSize = sizeof( si );
         si.pCertInfo = pCert->pCertInfo;
         si.hCryptProv = hKey;
         si.dwKeySpec = dwKeySpec;
         si.HashAlgorithm.pszObjId = ( LPSTR ) szOID_NIST_sha256;
         /* HashEncryptionAlgorithm: CryptoAPI takes it from the key */
         si.cAuthAttr = 1;
         si.rgAuthAttr = &attr;

         /* the chain of certificates (without the root), so that a reader can check it */
         memset( &chainPara, 0, sizeof( chainPara ) );
         chainPara.cbSize = sizeof( chainPara );
         certs[ nCerts ].cbData = pCert->cbCertEncoded;
         certs[ nCerts++ ].pbData = pCert->pbCertEncoded;
         if( CertGetCertificateChain( NULL, pCert, NULL, pCert->hCertStore, &chainPara, 0, NULL, &pChain ) && pChain->cChain > 0 )
         {
            PCERT_SIMPLE_CHAIN pSimple = pChain->rgpChain[ 0 ];
            DWORD i;
            for( i = 1; i < pSimple->cElement && nCerts < 16; i++ )
            {
               PCCERT_CONTEXT pC = pSimple->rgpElement[ i ]->pCertContext;
               certs[ nCerts ].cbData = pC->cbCertEncoded;
               certs[ nCerts++ ].pbData = pC->pbCertEncoded;
            }
         }

         memset( &sei, 0, sizeof( sei ) );
         sei.cbSize = sizeof( sei );
         sei.cSigners = 1;
         sei.rgSigners = &si;
         sei.cCertEncoded = nCerts;
         sei.rgCertEncoded = certs;

         hMsg = CryptMsgOpenToEncode( ENC_TYPE, CMSG_DETACHED_FLAG, CMSG_SIGNED, &sei, NULL, NULL );
         if( ! hMsg )
            hb_snprintf( szErr, sizeof( szErr ), "CryptMsgOpenToEncode - error 0x%08lX", ( unsigned long ) GetLastError() );
         else
         {
            if( ! CryptMsgUpdate( hMsg, ( const BYTE * ) hb_parc( 1 ), ( DWORD ) hb_parclen( 1 ), TRUE ) )
               hb_snprintf( szErr, sizeof( szErr ), "Signing failed (PIN cancelled?) - error 0x%08lX", ( unsigned long ) GetLastError() );
            else if( CryptMsgGetParam( hMsg, CMSG_CONTENT_PARAM, 0, NULL, &cbOut ) )
            {
               pOut = ( BYTE * ) hb_xgrab( cbOut + 1 );
               if( ! CryptMsgGetParam( hMsg, CMSG_CONTENT_PARAM, 0, pOut, &cbOut ) )
               {
                  hb_xfree( pOut );
                  pOut = NULL;
                  cbOut = 0;
               }
            }
            CryptMsgClose( hMsg );
         }
         if( pChain )
            CertFreeCertificateChain( pChain );
         if( hAes )
            CryptReleaseContext( hAes, 0 );
      }
      CertFreeCertificateContext( pCert );
   }
   if( hStore )
      CertCloseStore( hStore, 0 );
   if( pOut )
   {
      hb_retclen( ( const char * ) pOut, cbOut );
      hb_xfree( pOut );
   }
   else
   {
      if( ! szErr[ 0 ] )
         hb_snprintf( szErr, sizeof( szErr ), "Signing failed - error 0x%08lX", ( unsigned long ) GetLastError() );
      hb_retc_null();
   }
   hb_storc( szErr, 5 );
}

#endif
