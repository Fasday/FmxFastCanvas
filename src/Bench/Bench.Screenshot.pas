unit Bench.Screenshot;

{ Captures what is actually on screen in the client area of a window (after DWM composition),
  so that every canvas is checked through its real present path. The window must be visible
  and not covered. }

interface

uses
  Winapi.Windows;

procedure CaptureClientToPng(const AWnd: HWND; const AFileName: string);

implementation

uses
  System.SysUtils, System.UITypes, System.IOUtils, FMX.Graphics, FMX.Types;

const
  CAPTUREBLT = $40000000;

procedure CaptureClientToPng(const AWnd: HWND; const AFileName: string);
var
  R: TRect;
  P: TPoint;
  W, H, Y, X: Integer;
  ScreenDC, MemDC: HDC;
  Dib, OldObj: HBITMAP;
  Bits: Pointer;
  BI: TBitmapInfo;
  Line: TArray<TAlphaColor>;
  Src: PCardinal;
  Bmp: TBitmap;
  Data: TBitmapData;
  Dir: string;
begin
  if not GetClientRect(AWnd, R) then
    RaiseLastOSError;
  W := R.Width;
  H := R.Height;
  P := TPoint.Create(0, 0);
  ClientToScreen(AWnd, P);

  ScreenDC := GetDC(0);
  try
    MemDC := CreateCompatibleDC(ScreenDC);
    try
      FillChar(BI, SizeOf(BI), 0);
      BI.bmiHeader.biSize := SizeOf(BI.bmiHeader);
      BI.bmiHeader.biWidth := W;
      BI.bmiHeader.biHeight := -H;
      BI.bmiHeader.biPlanes := 1;
      BI.bmiHeader.biBitCount := 32;
      BI.bmiHeader.biCompression := BI_RGB;
      Dib := CreateDIBSection(ScreenDC, BI, DIB_RGB_COLORS, Bits, 0, 0);
      if Dib = 0 then
        RaiseLastOSError;
      try
        OldObj := SelectObject(MemDC, Dib);
        try
          if not BitBlt(MemDC, 0, 0, W, H, ScreenDC, P.X, P.Y, SRCCOPY or CAPTUREBLT) then
            RaiseLastOSError;
          GdiFlush;
          Bmp := TBitmap.Create(W, H);
          try
            SetLength(Line, W);
            if not Bmp.Map(TMapAccess.Write, Data) then
              raise Exception.Create('Cannot map screenshot bitmap');
            try
              for Y := 0 to H - 1 do
              begin
                Src := PCardinal(PByte(Bits) + NativeInt(Y) * W * 4);
                for X := 0 to W - 1 do
                begin
                  // GDI leaves the alpha byte undefined.
                  Line[X] := TAlphaColor(Src^ or $FF000000);
                  Inc(Src);
                end;
                AlphaColorToScanline(@Line[0], Data.GetScanline(Y), W, Data.PixelFormat);
              end;
            finally
              Bmp.Unmap(Data);
            end;
            Dir := TPath.GetDirectoryName(TPath.GetFullPath(AFileName));
            if (Dir <> '') and not TDirectory.Exists(Dir) then
              TDirectory.CreateDirectory(Dir);
            Bmp.SaveToFile(AFileName);
          finally
            Bmp.Free;
          end;
        finally
          SelectObject(MemDC, OldObj);
        end;
      finally
        DeleteObject(Dib);
      end;
    finally
      DeleteDC(MemDC);
    end;
  finally
    ReleaseDC(0, ScreenDC);
  end;
end;

end.
