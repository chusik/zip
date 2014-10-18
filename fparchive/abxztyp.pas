(* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is TurboPower Abbrevia
 *
 * The Initial Developer of the Original Code is
 * Joel Haynie
 * Craig Peterson
 *
 * Portions created by the Initial Developer are Copyright (C) 1997-2002
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 * Alexander Koblov <alexx2000@users.sourceforge.net>
 *
 * ***** END LICENSE BLOCK ***** *)

{*********************************************************}
{* ABBREVIA: AbXzTyp.pas                                 *}
{*********************************************************}
{* ABBREVIA: TAbXzArchive, TAbXzItem classes             *}
{*********************************************************}
{* Misc. constants, types, and routines for working      *}
{* with Xz files                                         *}
{*********************************************************}

unit AbXzTyp;

{$I AbDefine.inc}

interface

uses
  Classes,
  AbArcTyp, AbTarTyp, AbUtils;

const
  { The first six (6) bytes of the Stream are so called Header }
  { Magic Bytes. They can be used to identify the file type.   }
  AB_XZ_FILE_HEADER  =  #$FD'7zXZ'#00;

type
  PAbXzHeader = ^TAbXzHeader; { File Header }
  TAbXzHeader = packed record { SizeOf(TAbXzHeader) = 12 }
    HeaderMagic : array[0..5] of AnsiChar; { 0xFD, '7', 'z', 'X', 'Z', 0x00 }
    StreamFlags : Word;                    { 0x00, 0x00-0x0F }
    CRC32 : LongWord; { The CRC32 is calculated from the Stream Flags field }
  end;

{ The Purpose for this Item is the placeholder for aaAdd and aaDelete Support. }
{ For all intents and purposes we could just use a TAbArchiveItem }
type
  TAbXzItem = class(TabArchiveItem);

  TAbXzArchiveState = (gsXz, gsTar);

  TAbXzArchive = class(TAbTarArchive)
  private
    FBzip2Stream  : TStream;        { stream for Xz file}
    FBzip2Item    : TAbArchiveList; { item in xz (only one, but need polymorphism of class)}
    FTarStream    : TStream;        { stream for possible contained Tar }
    FTarList      : TAbArchiveList; { items in possible contained Tar }
    FTarAutoHandle: Boolean;
    FState        : TAbXzArchiveState;
    FIsBzippedTar : Boolean;

    procedure DecompressToStream(aStream: TStream);
    procedure SetTarAutoHandle(const Value: Boolean);
    procedure SwapToXz;
    procedure SwapToTar;

  protected
    { Inherited Abstract functions }
    function CreateItem(const SourceFileName   : string;
                        const ArchiveDirectory : string): TAbArchiveItem; override;
    procedure ExtractItemAt(Index : Integer; const NewName : string); override;
    procedure ExtractItemToStreamAt(Index : Integer; aStream : TStream); override;
    procedure LoadArchive; override;
    procedure SaveArchive; override;
    procedure TestItemAt(Index : Integer); override;
    function GetSupportsEmptyFolders : Boolean; override;

  public {methods}
    constructor CreateFromStream(aStream : TStream; const aArchiveName : string); override;
    destructor  Destroy; override;

    procedure DoSpanningMediaRequest(Sender : TObject; ImageNumber : Integer;
      var ImageName : string; var Abort : Boolean); override;

    { Properties }
    property TarAutoHandle : Boolean
      read FTarAutoHandle write SetTarAutoHandle;

    property IsBzippedTar : Boolean
      read FIsBzippedTar write FIsBzippedTar;
  end;

function VerifyXz(Strm : TStream) : TAbArchiveType;

implementation

uses
{$IFDEF MSWINDOWS}
  Windows, // Fix inline warnings
{$ENDIF}
  StrUtils, SysUtils,
  AbXz, AbExcept, AbVMStrm, AbBitBkt, CRC, DCOSUtils, DCClassesUtf8;

{ ****************** Helper functions Not from Classes Above ***************** }
function VerifyHeader(const Header : TAbXzHeader) : Boolean;
begin
  Result := CompareByte(Header.HeaderMagic, AB_XZ_FILE_HEADER, SizeOf(Header.HeaderMagic)) = 0;
  Result := Result and (crc32(0, PByte(@Header.StreamFlags), SizeOf(Header.StreamFlags)) = Header.CRC32);
end;
{ -------------------------------------------------------------------------- }
function VerifyXz(Strm : TStream) : TAbArchiveType;
var
  Hdr : TAbXzHeader;
  CurPos : int64;
  TarStream: TStream;
  DecompStream: TLzmaDecompression;
begin
  Result := atUnknown;

  CurPos := Strm.Position;
  Strm.Seek(0, soFromBeginning);

  try
    if (Strm.Read(Hdr, SizeOf(Hdr)) = SizeOf(Hdr)) and VerifyHeader(Hdr) then begin
      Result := atXz;
      { Check for embedded TAR }
      Strm.Seek(0, soFromBeginning);
      TarStream := TMemoryStream.Create;
      try
        DecompStream := TLzmaDecompression.Create(Strm, TarStream);
        try
          DecompStream.Code(512 * 2);
          TarStream.Seek(0, soFromBeginning);
          if VerifyTar(TarStream) = atTar then
            Result := atXzTar;
        finally
          DecompStream.Free;
        end;
      finally
       TarStream.Free;
      end;
    end;
  except
    on EReadError do
      Result := atUnknown;
  end;
  Strm.Position := CurPos; { Return to original position. }
end;


{ ****************************** TAbXzArchive ***************************** }
constructor TAbXzArchive.CreateFromStream(aStream: TStream;
  const aArchiveName: string);
begin
  inherited CreateFromStream(aStream, aArchiveName);
  FState       := gsXz;
  FBzip2Stream := FStream;
  FBzip2Item   := FItemList;
  FTarStream   := TAbVirtualMemoryStream.Create;
  FTarList     := TAbArchiveList.Create(True);
end;
{ -------------------------------------------------------------------------- }
procedure TAbXzArchive.SwapToTar;
begin
  FStream   := FTarStream;
  FItemList := FTarList;
  FState    := gsTar;
end;
{ -------------------------------------------------------------------------- }
procedure TAbXzArchive.SwapToXz;
begin
  FStream   := FBzip2Stream;
  FItemList := FBzip2Item;
  FState    := gsXz;
end;
{ -------------------------------------------------------------------------- }
function TAbXzArchive.CreateItem(const SourceFileName   : string;
                                    const ArchiveDirectory : string): TAbArchiveItem;
var
  Bz2Item : TAbXzItem;
  FullSourceFileName, FullArchiveFileName: String;
begin
  if IsBzippedTar and TarAutoHandle then begin
    SwapToTar;
    Result := inherited CreateItem(SourceFileName, ArchiveDirectory);
  end
  else begin
    SwapToXz;
    Bz2Item := TAbXzItem.Create;
    try
      MakeFullNames(SourceFileName, ArchiveDirectory,
                    FullSourceFileName, FullArchiveFileName);

      Bz2Item.FileName := FullArchiveFileName;
      Bz2Item.DiskFileName := FullSourceFileName;

      Result := Bz2Item;
    except
      Result := nil;
      raise;
    end;
  end;
end;
{ -------------------------------------------------------------------------- }
destructor TAbXzArchive.Destroy;
begin
  SwapToXz;
  FTarList.Free;
  FTarStream.Free;
  inherited Destroy;
end;
{ -------------------------------------------------------------------------- }
procedure TAbXzArchive.ExtractItemAt(Index: Integer;
  const NewName: string);
var
  OutStream : TStream;
begin
  if IsBzippedTar and TarAutoHandle then begin
    SwapToTar;
    inherited ExtractItemAt(Index, NewName);
  end
  else begin
    SwapToXz;
    OutStream := TFileStreamEx.Create(NewName, fmCreate or fmShareDenyNone);
    try
      try
        ExtractItemToStreamAt(Index, OutStream);
      finally
        OutStream.Free;
      end;
      { Bz2 doesn't store the last modified time or attributes, so don't set them }
    except
      on E : EAbUserAbort do begin
        FStatus := asInvalid;
        if mbFileExists(NewName) then
          mbDeleteFile(NewName);
        raise;
      end else begin
        if mbFileExists(NewName) then
          mbDeleteFile(NewName);
        raise;
      end;
    end;
  end;
end;
{ -------------------------------------------------------------------------- }
procedure TAbXzArchive.ExtractItemToStreamAt(Index: Integer;
  aStream: TStream);
begin
  if IsBzippedTar and TarAutoHandle then begin
    SwapToTar;
    inherited ExtractItemToStreamAt(Index, aStream);
  end
  else begin
    SwapToXz;
    { Index ignored as there's only one item in a Bz2 }
    DecompressToStream(aStream);
  end;
end;
{ -------------------------------------------------------------------------- }
function TAbXzArchive.GetSupportsEmptyFolders : Boolean;
begin
  Result := IsBzippedTar and TarAutoHandle;
end;
{ -------------------------------------------------------------------------- }
procedure TAbXzArchive.LoadArchive;
var
  Item: TAbXzItem;
  Abort: Boolean;
  ItemName: string;
begin
  if FBzip2Stream.Size = 0 then
    Exit;

  if IsBzippedTar and TarAutoHandle then begin
    { Decompress and send to tar LoadArchive }
    DecompressToStream(FTarStream);
    SwapToTar;
    inherited LoadArchive;
  end
  else begin
    SwapToXz;
    Item := TAbXzItem.Create;
    Item.Action := aaNone;
    { Filename isn't stored, so constuct one based on the archive name }
    ItemName := ExtractFileName(ArchiveName);
    if ItemName = '' then
      Item.FileName := 'unknown'
    else if AnsiEndsText('.txz', ItemName) then
      Item.FileName := ChangeFileExt(ItemName, '.tar')
    else
      Item.FileName := ChangeFileExt(ItemName, '');
    Item.DiskFileName := Item.FileName;
    FItemList.Add(Item);
  end;
  DoArchiveProgress(100, Abort);
  FIsDirty := False;
end;
{ -------------------------------------------------------------------------- }
procedure TAbXzArchive.SaveArchive;
var
  i: Integer;
  CurItem: TAbXzItem;
  InputFileStream: TStream;
  LzmaCompression: TLzmaCompression;
begin
  if IsBzippedTar and TarAutoHandle then
  begin
    SwapToTar;
    inherited SaveArchive;
    FTarStream.Position := 0;
    FBzip2Stream.Size := 0;
    LzmaCompression := TLzmaCompression.Create(FTarStream, FBzip2Stream);
    try
      LzmaCompression.Code();
    finally
      LzmaCompression.Free;
    end;
  end
  else begin
    { Things we know: There is only one file per archive.}
    { Actions we have to address in SaveArchive: }
    { aaNone & aaMove do nothing, as the file does not change, only the meta data }
    { aaDelete could make a zero size file unless there are two files in the list.}
    { aaAdd, aaStreamAdd, aaFreshen, & aaReplace will be the only ones to take action. }
    SwapToXz;
    for i := 0 to pred(Count) do begin
      FCurrentItem := ItemList[i];
      CurItem      := TAbXzItem(ItemList[i]);
      case CurItem.Action of
        aaNone, aaMove: Break;{ Do nothing; xz doesn't store metadata }
        aaDelete: ; {doing nothing omits file from new stream}
        aaAdd, aaFreshen, aaReplace, aaStreamAdd: begin
          FBzip2Stream.Size := 0;
          if CurItem.Action = aaStreamAdd then
          begin
            LzmaCompression := TLzmaCompression.Create(InStream, FBzip2Stream);
            try
              LzmaCompression.Code(); { Copy/compress entire Instream to FBzip2Stream }
            finally
              LzmaCompression.Free;
            end;
          end
          else begin
            InputFileStream := TFileStreamEx.Create(CurItem.DiskFileName, fmOpenRead or fmShareDenyWrite );
            LzmaCompression := TLzmaCompression.Create(InputFileStream, FBzip2Stream);
            try
              LzmaCompression.Code(); { Copy/compress entire Instream to FBzip2Stream }
            finally
              InputFileStream.Free;
            end;
          end;
          Break;
        end; { End aaAdd, aaFreshen, aaReplace, & aaStreamAdd }
      end; { End of CurItem.Action Case }
    end; { End Item for loop }
  end; { End Tar Else }
end;
{ -------------------------------------------------------------------------- }
procedure TAbXzArchive.SetTarAutoHandle(const Value: Boolean);
begin
  if Value then
    SwapToTar
  else
    SwapToXz;
  FTarAutoHandle := Value;
end;
{ -------------------------------------------------------------------------- }
procedure TAbXzArchive.DecompressToStream(aStream: TStream);
var
  LzmaDecompression: TLzmaDecompression;
  Buffer: PByte;
  N: Integer;
begin
  LzmaDecompression := TLzmaDecompression.Create(FBzip2Stream, aStream);
  try
    LzmaDecompression.Code
  finally
    LzmaDecompression.Free;
  end;
end;
{ -------------------------------------------------------------------------- }
procedure TAbXzArchive.TestItemAt(Index: Integer);
var
  Bzip2Type: TAbArchiveType;
  BitBucket: TAbBitBucketStream;
begin
  if IsBzippedTar and TarAutoHandle then begin
    SwapToTar;
    inherited TestItemAt(Index);
  end
  else begin
    { note Index ignored as there's only one item in a GZip }
    Bzip2Type := VerifyXz(FBzip2Stream);
    if not (Bzip2Type in [atBzip2, atBzippedTar]) then
      raise EAbGzipInvalid.Create;// TODO: Add bzip2-specific exceptions }
    BitBucket := TAbBitBucketStream.Create(1024);
    try
      DecompressToStream(BitBucket);
    finally
      BitBucket.Free;
    end;
  end;
end;
{ -------------------------------------------------------------------------- }
procedure TAbXzArchive.DoSpanningMediaRequest(Sender: TObject;
  ImageNumber: Integer; var ImageName: string; var Abort: Boolean);
begin
  Abort := False;
end;

end.
