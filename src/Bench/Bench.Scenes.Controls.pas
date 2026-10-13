unit Bench.Scenes.Controls;

{ Scenes with real FMX controls and offscreen bitmaps.

  controls      N standard controls with the default style in a grid inside a TLayout. Per frame the
                layout moves by a fractional offset, the progress bars and one label change. Check
                states and disabled controls are set in Setup only: their style trigger animations
                end during warm-up. All controls have HitTest and CanFocus off and a transparent layer
                on top takes the mouse, so no IsMouseOver animation and no caret can start.
  effects       N moving rounded rectangles with a text: 6 of 8 have a TShadowEffect, 1 of 8 a
                TGlowEffect, 1 of 8 a TBlurEffect. Shadow and glow (TEffectStyle = []) keep their
                cached bitmap while the control only moves; blur (DisablePaint) is invalidated by
                every Repaint, so it is rendered again every frame (FMX.Controls.pas:3633,
                FMX.Effects.pas:497, :537, :639).
  offscreen     The rects content drawn every frame into a persistent TBitmap of the client size in
                physical pixels (Bitmap.Canvas.BeginScene/EndScene), then DrawBitmap onto the form.
  offscreenmap  Like offscreen, plus TBitmap.Map(Read) after EndScene and a few pixel reads: the
                GPU->CPU sync point on GPU canvases. }

interface

implementation

uses
  System.SysUtils, System.Types, System.UITypes, System.Math, System.Math.Vectors, FMX.Types,
  FMX.Graphics, FMX.Controls, FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.ListBox, FMX.SpinBox,
  FMX.Objects, FMX.Effects, Bench.Config, Bench.Scenes;

type
  TControlKind = (Button, Edit, Caption, CheckBox, RadioButton, ComboBox, TrackBar, ProgressBar, Switch,
    SpinBox);

  TControlsScene = class(TBenchScene)
  private const
    Margin = 12;
    MotionAmplitude = 5.5;
  private
    FContainer: TLayout;
    FProgressBars: TArray<TProgressBar>;
    FStatus: TLabel;
    FRadioCount: Integer;
    function CreateControl(const AKind: TControlKind; const AIndex: Integer; var ARnd: TBenchRandom): TControl;
  protected
    procedure DoAdvance; override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

  TEffectsScene = class(TBenchScene)
  private
    FItems: TArray<TMovingItem>;
    FShapes: TArray<TRectangle>;
  protected
    procedure DoAdvance; override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

  TOffscreenScene = class(TBenchPaintScene)
  private
    FItems: TArray<TMovingItem>;
    FBitmap: TBitmap;
  protected
    procedure Draw(const ACanvas: TCanvas; const ARect: TRectF); override;
    /// <summary>Called after the bitmap scene has ended, before the bitmap is drawn.</summary>
    procedure AfterOffscreen; virtual;
    property Bitmap: TBitmap read FBitmap;
  public
    destructor Destroy; override;
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

  TOffscreenMapScene = class(TOffscreenScene)
  private
    FChecksum: TAlphaColor;
  protected
    procedure AfterOffscreen; override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
  end;

{ TControlsScene }

class function TControlsScene.Name: string;
begin
  Result := 'controls';
end;

class function TControlsScene.Description: string;
begin
  Result := 'N standard styled controls in a grid, container moves, progress bars change';
end;

class function TControlsScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~2 / ~9 / ~20 ms (~45 us per control, measured 2026-10-06).
  case APreset of
    TBenchPreset.Light: Result := 40;
    TBenchPreset.Heavy: Result := 460;
  else
    Result := 190;
  end;
end;

function TControlsScene.CreateControl(const AKind: TControlKind; const AIndex: Integer;
  var ARnd: TBenchRandom): TControl;
var
  Num: string;
begin
  Num := IntToStr(AIndex);
  case AKind of
    TControlKind.Button:
      begin
        Result := TButton.Create(Form);
        TButton(Result).Text := 'Button ' + Num;
      end;
    TControlKind.Edit:
      begin
        Result := TEdit.Create(Form);
        TEdit(Result).Text := 'Edit text ' + Num;
      end;
    TControlKind.Caption:
      begin
        Result := TLabel.Create(Form);
        TLabel(Result).WordWrap := False;
        TLabel(Result).Text := 'Label ' + Num + ':';
        if FStatus = nil then
          FStatus := TLabel(Result);
      end;
    TControlKind.CheckBox:
      begin
        Result := TCheckBox.Create(Form);
        TCheckBox(Result).Text := 'Option ' + Num;
        TCheckBox(Result).IsChecked := ARnd.NextFloat < 0.5;
      end;
    TControlKind.RadioButton:
      begin
        Result := TRadioButton.Create(Form);
        TRadioButton(Result).Text := 'Choice ' + Num;
        // Consecutive radio buttons form groups of two; the first one of a group is checked.
        TRadioButton(Result).GroupName := 'g' + IntToStr(FRadioCount div 2);
        TRadioButton(Result).IsChecked := FRadioCount mod 2 = 0;
        Inc(FRadioCount);
      end;
    TControlKind.ComboBox:
      begin
        Result := TComboBox.Create(Form);
        TComboBox(Result).Items.Add('Item A' + Num);
        TComboBox(Result).Items.Add('Item B' + Num);
        TComboBox(Result).Items.Add('Item C' + Num);
        TComboBox(Result).ItemIndex := ARnd.RangeInt(0, 2);
      end;
    TControlKind.TrackBar:
      begin
        Result := TTrackBar.Create(Form);
        TTrackBar(Result).Max := 100;
        TTrackBar(Result).Value := ARnd.RangeInt(0, 100);
      end;
    TControlKind.ProgressBar:
      begin
        Result := TProgressBar.Create(Form);
        FProgressBars := FProgressBars + [TProgressBar(Result)];
      end;
    TControlKind.Switch:
      begin
        Result := TSwitch.Create(Form);
        TSwitch(Result).IsChecked := ARnd.NextFloat < 0.5;
      end;
  else
    begin
      Result := TSpinBox.Create(Form);
      TSpinBox(Result).Value := ARnd.RangeInt(0, 100);
    end;
  end;
end;

procedure TControlsScene.Setup;
const
  CellAspect = 4;
  MaxControlWidth = 200;
  MaxControlHeight = 26;
var
  Rnd: TBenchRandom;
  W, H, CellW, CellH, CW, CH: Single;
  Cols, Rows, I: Integer;
  C: TControl;
  Shield: TLayout;
begin
  // Cells with a width:height ratio of about CellAspect that fill the client area.
  W := Form.ClientWidth - 2 * Margin;
  H := Form.ClientHeight - 2 * Margin;
  Cols := Max(1, Ceil(Sqrt(N * W / (H * CellAspect))));
  Rows := (N + Cols - 1) div Cols;
  CellW := Floor(W / Cols);
  CellH := Floor(H / Rows);
  CW := Min(CellW - 4, MaxControlWidth);
  CH := Min(CellH - 4, MaxControlHeight);

  FContainer := TLayout.Create(Form);
  FContainer.HitTest := False;
  FContainer.SetBounds(Margin, Margin, Cols * CellW, Rows * CellH);
  FContainer.Parent := Form;

  Rnd := TBenchRandom.Create(21);
  for I := 0 to N - 1 do
  begin
    // Every kind gets 1/10 of the cells; the shift by 3 per row mixes the kinds in every column.
    C := CreateControl(TControlKind((I + 3 * (I div Cols)) mod (Ord(High(TControlKind)) + 1)), I, Rnd);
    C.SetBounds((I mod Cols) * CellW + 2, (I div Cols) * CellH + Round((CellH - CH) / 2), CW, CH);
    C.HitTest := False;
    C.CanFocus := False;
    if I mod 7 = 5 then
      C.Enabled := False;
    C.Parent := FContainer;
  end;

  // Transparent layer on top: it receives all mouse input, so a cursor over the window cannot
  // start IsMouseOver style animations in presentation children that keep HitTest on.
  Shield := TLayout.Create(Form);
  Shield.Align := TAlignLayout.Contents;
  Shield.Parent := Form;
end;

procedure TControlsScene.DoAdvance;
var
  I: Integer;
begin
  // The container is a child of the form: its move also runs TCustomForm.Realign once
  // (FMX.Controls.pas:2060-2067).
  FContainer.Position.Point := TPointF.Create(Margin + MotionAmplitude * Sin(Time * 2.0),
    Margin + MotionAmplitude * Cos(Time * 1.5));
  for I := 0 to High(FProgressBars) do
    FProgressBars[I].Value := (Frame * 2 + I * 13) mod 101;
  if FStatus <> nil then
    FStatus.Text := 'Frame ' + IntToStr(Frame);
end;

{ TEffectsScene }

class function TEffectsScene.Name: string;
begin
  Result := 'effects';
end;

class function TEffectsScene.Description: string;
begin
  Result := 'N moving TRectangle+TText: 6/8 TShadowEffect, 1/8 TGlowEffect, 1/8 TBlurEffect';
end;

class function TEffectsScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // D2D throughput frame: ~2 / ~9 / ~20 ms (~80 us per item, measured 2026-10-06); the blurred
  // items (1/8) take most of it, ~0.45 ms each. Multiples of 8 keep the effect mix exact.
  case APreset of
    TBenchPreset.Light: Result := 24;
    TBenchPreset.Heavy: Result := 208;
  else
    Result := 112;
  end;
end;

procedure TEffectsScene.Setup;
var
  I: Integer;
  R: TRectangle;
  T: TText;
  Glow: TGlowEffect;
  Container: TLayout;
begin
  // The shapes are not direct children of the form: every position change of a form child calls
  // TCustomForm.Realign, which aligns all children and recalculates all update rects
  // (FMX.Controls.pas:2060-2067, FMX.Forms.pas:6626-6643), O(N^2) per frame. TControl.DoRealign
  // exits at once when no child is aligned (FMX.Controls.pas:4027).
  Container := TLayout.Create(Form);
  Container.Align := TAlignLayout.Contents;
  Container.HitTest := False;
  Container.Parent := Form;

  GenerateMovingItems(FItems, N, 31, 48, 128);
  SetLength(FShapes, N);
  for I := 0 to N - 1 do
  begin
    R := TRectangle.Create(Form);
    R.HitTest := False;
    R.Fill.Color := FItems[I].Color;
    R.Stroke.Kind := TBrushKind.None;
    R.XRadius := 8;
    R.YRadius := 8;
    R.SetBounds(0, 0, Round(FItems[I].W), Round(FItems[I].H));

    T := TText.Create(Form);
    T.Align := TAlignLayout.Client;
    T.HitTest := False;
    T.TextSettings.FontColor := TAlphaColors.White;
    T.Text := 'Card ' + IntToStr(I);
    T.Parent := R;

    case I mod 8 of
      6:
        begin
          Glow := TGlowEffect.Create(Form);
          Glow.GlowColor := TAlphaColors.Gold;
          Glow.Parent := R;
        end;
      7:
        TBlurEffect.Create(Form).Parent := R;
    else
      TShadowEffect.Create(Form).Parent := R;
    end;

    R.Parent := Container;
    FShapes[I] := R;
  end;
end;

procedure TEffectsScene.DoAdvance;
var
  Bounds: TRectF;
  I: Integer;
begin
  Bounds := TRectF.Create(0, 0, Form.ClientWidth, Form.ClientHeight);
  // Every move calls Repaint, which still invalidates the blur caches (FMX.Controls.pas:3633), and
  // then InvalidateRect of the window for the control (FMX.Forms.pas:6369-6378,
  // FMX.Platform.Win.pas:3236-3237). These calls grow superlinearly with N (1 ms for 64 moves,
  // 3.6 ms for 160) and run outside PaintRects; the runner invalidates the whole form after
  // Advance anyway, so the scene suppresses them.
  (Form as IScene).DisableUpdating;
  try
    for I := 0 to High(FShapes) do
      FShapes[I].Position.Point := MovingItemRect(FItems[I], Bounds, Time).TopLeft;
  finally
    (Form as IScene).EnableUpdating;
  end;
end;

{ TOffscreenScene }

destructor TOffscreenScene.Destroy;
begin
  FBitmap.Free;
  inherited;
end;

class function TOffscreenScene.Name: string;
begin
  Result := 'offscreen';
end;

class function TOffscreenScene.Description: string;
begin
  Result := 'rects drawn into a client-size TBitmap every frame, then DrawBitmap';
end;

class function TOffscreenScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // Same N as rects: on D2D the offscreen pass adds almost nothing (14000 rects: 7.36 ms against
  // 7.32 ms for rects, measured 2026-10-06), so the presets give ~2 / ~9 / ~20 ms as well.
  case APreset of
    TBenchPreset.Light: Result := 4000;
    TBenchPreset.Heavy: Result := 36000;
  else
    Result := 16000;
  end;
end;

procedure TOffscreenScene.Setup;
begin
  inherited;
  // Same seed and sizes as the rects scene: the picture must match it.
  GenerateMovingItems(FItems, N, 1, 8, 96);
end;

procedure TOffscreenScene.AfterOffscreen;
begin
end;

procedure TOffscreenScene.Draw(const ACanvas: TCanvas; const ARect: TRectF);
var
  S: Single;
  W, H, I: Integer;
  C: TCanvas;
begin
  S := ACanvas.Scale;
  W := Round(ARect.Width * S);
  H := Round(ARect.Height * S);
  if (FBitmap = nil) or (FBitmap.Width <> W) or (FBitmap.Height <> H) then
  begin
    FreeAndNil(FBitmap);
    FBitmap := TBitmap.Create(W, H);
  end;

  C := FBitmap.Canvas;
  if C.BeginScene then
    try
      C.Clear(TAlphaColors.White);
      // Logical coordinates as on the form; the bitmap has one pixel per physical pixel.
      C.SetMatrix(TMatrix.CreateScaling(S, S));
      C.Fill.Kind := TBrushKind.Solid;
      for I := 0 to High(FItems) do
      begin
        C.Fill.Color := FItems[I].Color;
        C.FillRect(MovingItemRect(FItems[I], ARect, Time), 0, 0, [], 1);
      end;
    finally
      C.EndScene;
    end;
  AfterOffscreen;
  ACanvas.DrawBitmap(FBitmap, FBitmap.BoundsF, ARect, 1, True);
end;

{ TOffscreenMapScene }

class function TOffscreenMapScene.Name: string;
begin
  Result := 'offscreenmap';
end;

class function TOffscreenMapScene.Description: string;
begin
  Result := 'offscreen + Map(Read) and 8 pixel reads after EndScene (GPU->CPU sync)';
end;

class function TOffscreenMapScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // Same N as offscreen: the difference of the two scenes is the cost of the Map path.
  Result := TOffscreenScene.DefaultN(APreset);
end;

procedure TOffscreenMapScene.AfterOffscreen;
const
  Probes = 8;
var
  Data: TBitmapData;
  I: Integer;
begin
  if Bitmap.Map(TMapAccess.Read, Data) then
    try
      for I := 0 to Probes - 1 do
        FChecksum := FChecksum xor Data.GetPixel((Data.Width - 1) * I div (Probes - 1),
          (Data.Height - 1) * I div (Probes - 1));
    finally
      Bitmap.Unmap(Data);
    end;
end;

initialization
  RegisterBenchScene(TControlsScene);
  RegisterBenchScene(TEffectsScene);
  RegisterBenchScene(TOffscreenScene);
  RegisterBenchScene(TOffscreenMapScene);
end.
