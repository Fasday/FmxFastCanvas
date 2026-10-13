unit Bench.Scenes.Lists;

{ List scenes: stock TListBox and TListView with the default style, scrolled from Time.

  listbox   TListBox, style listboxitembottomdetail: text, detail, checkbox, some items with an
            accessory. Only the visible range is painted (TListBoxContent returns it as the visible
            object range, FMX.ListBox.pas:1633-1641, used by FMX.Controls.pas:4286). Items that leave
            the viewport hand their style objects to TStyleCache (FMX.ListBox.pas:2582-2596,
            FMX.Controls.pas:5799-5805, 5882-5898); items that enter it are styled again before the
            paint (PrepareForPaint, FMX.Forms.pas:6522, FMX.Controls.pas:5833-5837, 6045-6074). Their
            invalidations then make FMX call PaintRects a second time in the same WM_PAINT
            (FMX.Platform.Win.pas:1803-1811). Nothing is cached as a bitmap: every visible item redraws
            its whole style tree each frame.
  listview  TListView, appearance ImageListItemBottomDetail: bitmap, text, detail, accessory. The
            bitmaps are 16 procedural TBitmaps shared through TListViewItem.BitmapRef. The control
            draws the visible items itself in Paint (FMX.ListView.pas:3393-3638); each text drawable
            keeps its own TTextLayout (FMX.ListView.Types.pas:1955-1996).

  Scrolling: a ping-pong over the whole content at ScreensPerSecond viewport heights per second of
  scene time, snapped to physical pixels as FMX does (FMX.Layouts.pas:2656-2664,
  FMX.ListView.pas:3026-3027). TListBox: ViewportPosition goes through TAniCalculations, which
  postpones changes closer than 10 ms to its next display-link tick
  (FMX.InertialMovement.pas:1346-1361), so the scene realigns the list box to apply the position in
  the same frame. TListView on a machine without touch input has no TAniCalculations
  (FMX.ListView.pas:1211-1224) and applies ScrollViewPos synchronously (:2911-2923, :5102-5113).
  Kinetic scrolling, bounces and scrollbar fading are off on non-touch Windows
  (FMX.Platform.Metrics.Win.pas:78-87); the list box disables them explicitly as well.

  N is the total number of items. The frame cost does not depend on the number of items in a list
  (one list of 200, 2000 or 20000 items: same frame time), only on the visible ones, so N is split
  into side-by-side lists of ItemsPerList items each: the number of lists is the per-frame knob.
  Many lists make narrow columns; beyond ~16 lists at 1920 logical px the text no longer fits. }

interface

implementation

uses
  System.SysUtils, System.Types, System.UITypes, System.Math, System.Messaging, FMX.Types,
  FMX.BehaviorManager, FMX.Graphics, FMX.Controls, FMX.ListBox, FMX.ListView, FMX.ListView.Types,
  FMX.ListView.Appearances, Bench.Config, Bench.Scenes;

const
  ItemsPerList = 1000;
  ScreensPerSecond = 3;
  GoldenRatio = 0.6180339887;
  ListBoxItemHeight = 44;
  ListViewItemHeight = 56;
  ThumbnailCount = 16;
  ThumbnailSize = 96;

type
  TListSceneBase = class(TBenchScene)
  private
    FLists: TArray<TControl>;
    FLayoutWidth: Integer;
    procedure LayoutLists;
  protected
    procedure FreeLists;
    /// <summary>Creates an empty list; the caller aligns and parents it, then calls FillList.</summary>
    function CreateList: TControl; virtual; abstract;
    procedure FillList(const AList: TControl; const AFirstItem, ACount: Integer; var ARnd: TBenchRandom);
      virtual; abstract;
    function ScrollRange(const AList: TControl): Single; virtual; abstract;
    procedure ScrollTo(const AList: TControl; const APosition: Single); virtual; abstract;
    procedure DoAdvance; override;
  public
    destructor Destroy; override;
    procedure Setup; override;
  end;

  TListBoxAccess = class(TListBox);

  TListBoxScene = class(TListSceneBase)
  protected
    function CreateList: TControl; override;
    procedure FillList(const AList: TControl; const AFirstItem, ACount: Integer; var ARnd: TBenchRandom);
      override;
    function ScrollRange(const AList: TControl): Single; override;
    procedure ScrollTo(const AList: TControl; const APosition: Single); override;
    procedure DoAdvance; override;
  public
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
  end;

  TListViewScene = class(TListSceneBase)
  private
    FThumbnails: TArray<TBitmap>;
  protected
    function CreateList: TControl; override;
    procedure FillList(const AList: TControl; const AFirstItem, ACount: Integer; var ARnd: TBenchRandom);
      override;
    function ScrollRange(const AList: TControl): Single; override;
    procedure ScrollTo(const AList: TControl; const APosition: Single); override;
  public
    destructor Destroy; override;
    class function Name: string; override;
    class function Description: string; override;
    class function DefaultN(const APreset: TBenchPreset): Integer; override;
    procedure Setup; override;
  end;

function RandomWord(var ARnd: TBenchRandom): string;
var
  Len, I, Base: Integer;
begin
  Len := ARnd.RangeInt(2, 9);
  if ARnd.NextFloat < 0.25 then
    Base := $0430  // Cyrillic small a
  else
    Base := Ord('a');
  SetLength(Result, Len);
  for I := 1 to Len do
    Result[I] := Char(Base + ARnd.RangeInt(0, 25));
end;

function RandomPhrase(var ARnd: TBenchRandom; const AMinWords, AMaxWords: Integer;
  const ACapitalize: Boolean): string;
var
  I: Integer;
begin
  Result := RandomWord(ARnd);
  // Both 'a'..'z' and U+0430..U+044F have their capitals 32 code points lower.
  if ACapitalize then
    Result[1] := Char(Ord(Result[1]) - 32);
  for I := 2 to ARnd.RangeInt(AMinWords, AMaxWords) do
    Result := Result + ' ' + RandomWord(ARnd);
end;

function LerpColor(const A, B: TAlphaColor; const T: Single): TAlphaColor;
var
  CA, CB, R: TAlphaColorRec;
begin
  CA := TAlphaColorRec(A);
  CB := TAlphaColorRec(B);
  R.A := $FF;
  R.R := Round(CA.R + (CB.R - CA.R) * T);
  R.G := Round(CA.G + (CB.G - CA.G) * T);
  R.B := Round(CA.B + (CB.B - CA.B) * T);
  Result := R.Color;
end;

/// <summary>Opaque thumbnail: diagonal gradient with one of four patterns (disc, stripes, checker,
/// ring) in a third color.</summary>
function CreateThumbnail(const AIndex: Integer): TBitmap;
var
  Rnd: TBenchRandom;
  C1, C2, C3, C: TAlphaColor;
  Data: TBitmapData;
  X, Y: Integer;
  U, V, D: Single;
begin
  Rnd := TBenchRandom.Create(UInt64(1000 + AIndex));
  C1 := Rnd.Color;
  C2 := Rnd.Color;
  C3 := Rnd.Color;
  Result := TBitmap.Create(ThumbnailSize, ThumbnailSize);
  try
    if not Result.Map(TMapAccess.Write, Data) then
      raise Exception.Create('TBitmap.Map failed');
    try
      for Y := 0 to ThumbnailSize - 1 do
        for X := 0 to ThumbnailSize - 1 do
        begin
          U := X / (ThumbnailSize - 1);
          V := Y / (ThumbnailSize - 1);
          C := LerpColor(C1, C2, (U + V) * 0.5);
          D := Sqrt(Sqr(U - 0.5) + Sqr(V - 0.5));
          case AIndex mod 4 of
            0:
              if D < 0.3 then
                C := C3;
            1:
              if Frac((U + V) * 4) < 0.5 then
                C := LerpColor(C, C3, 0.6);
            2:
              if Odd(X div 16 + Y div 16) then
                C := LerpColor(C, C3, 0.5);
          else
            if Abs(D - 0.3) < 0.08 then
              C := C3;
          end;
          Data.SetPixel(X, Y, C);
        end;
    finally
      Result.Unmap(Data);
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ TListSceneBase }

destructor TListSceneBase.Destroy;
begin
  FreeLists;
  inherited;
end;

procedure TListSceneBase.FreeLists;
var
  L: TControl;
begin
  for L in FLists do
    L.Free;
  FLists := nil;
end;

procedure TListSceneBase.Setup;
var
  Rnd: TBenchRandom;
  Count, I, First, ItemCount: Integer;
begin
  Rnd := TBenchRandom.Create(11);
  Count := Max(1, (N + ItemsPerList - 1) div ItemsPerList);
  SetLength(FLists, Count);
  for I := 0 to Count - 1 do
  begin
    FLists[I] := CreateList;
    FLists[I].HitTest := False;
    if I < Count - 1 then
      FLists[I].Align := TAlignLayout.Left
    else
      FLists[I].Align := TAlignLayout.Client;
  end;
  LayoutLists;
  First := 0;
  for I := 0 to Count - 1 do
  begin
    FLists[I].Parent := Form;
    ItemCount := N div Count + Ord(I < N mod Count);
    FillList(FLists[I], First, ItemCount, Rnd);
    Inc(First, ItemCount);
  end;
end;

procedure TListSceneBase.LayoutLists;
var
  I: Integer;
  W: Single;
begin
  FLayoutWidth := Form.ClientWidth;
  W := FLayoutWidth / Length(FLists);
  for I := 0 to High(FLists) - 1 do
  begin
    FLists[I].Position.X := I * W;
    FLists[I].Width := W;
  end;
end;

procedure TListSceneBase.DoAdvance;
var
  I: Integer;
  Range, Distance, P, Scale: Double;
begin
  if FLayoutWidth <> Form.ClientWidth then
    LayoutLists;
  Scale := 1;
  if Form.Handle <> nil then
    Scale := Form.Handle.Scale;
  for I := 0 to High(FLists) do
  begin
    Range := ScrollRange(FLists[I]);
    P := 0;
    if Range > 0 then
    begin
      Distance := Time * ScreensPerSecond * FLists[I].Height + Frac(I * GoldenRatio) * 2 * Range;
      P := Distance - Floor(Distance / (2 * Range)) * 2 * Range;
      if P > Range then
        P := 2 * Range - P;
      P := Round(P * Scale) / Scale;
    end;
    ScrollTo(FLists[I], P);
  end;
end;

{ TListBoxScene }

class function TListBoxScene.Name: string;
begin
  Result := 'listbox';
end;

class function TListBoxScene.Description: string;
begin
  Result := 'TListBox, N items (text, bottom detail, checkbox, accessories), 1000 per list, scrolled';
end;

class function TListBoxScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // 1 / 4 / 7 lists. D2D throughput frame 1.9 / 10.0 / ~20 ms at 1920x1080 logical px, including the
  // second PaintRects of each frame (measured 2026-10-06 with --size=2880x1620 on the 150% monitor).
  case APreset of
    TBenchPreset.Light: Result := 1000;
    TBenchPreset.Heavy: Result := 7000;
  else
    Result := 4000;
  end;
end;

function TListBoxScene.CreateList: TControl;
var
  LB: TListBox;
begin
  LB := TListBox.Create(Form);
  LB.CanFocus := False;
  LB.ScrollAnimation := TBehaviorBoolean.False;
  LB.Bounces := TBehaviorBoolean.False;
  LB.TouchTracking := TBehaviorBoolean.False;
  LB.ItemHeight := ListBoxItemHeight;
  LB.DefaultItemStyles.ItemStyle := 'listboxitembottomdetail';
  LB.ShowCheckboxes := True;
  Result := LB;
end;

procedure TListBoxScene.FillList(const AList: TControl; const AFirstItem, ACount: Integer;
  var ARnd: TBenchRandom);
var
  LB: TListBox;
  Item: TListBoxItem;
  I: Integer;
  R: Single;
begin
  LB := TListBox(AList);
  // Without its style the list box has no content layout and cannot position the items
  // (FMX.Layouts.pas:1843), so they all stay at the top and count as visible
  // (FMX.ListBox.pas:2526-2575): the first paint would style every item, and the styles would stay
  // in TStyleCache (2.4 GB working set with 20000 items instead of 0.2 GB).
  LB.ApplyStyleLookup;
  LB.BeginUpdate;
  try
    for I := 0 to ACount - 1 do
    begin
      Item := TListBoxItem.Create(LB);
      Item.HitTest := False;
      Item.Text := RandomPhrase(ARnd, 2, 4, True);
      Item.ItemData.Detail := Format('#%d  %s', [AFirstItem + I + 1, RandomPhrase(ARnd, 3, 8, False)]);
      R := ARnd.NextFloat;
      if R < 0.25 then
        Item.ItemData.Accessory := TListBoxItemData.TAccessory.aMore
      else if R < 0.375 then
        Item.ItemData.Accessory := TListBoxItemData.TAccessory.aDetail
      else if R < 0.5 then
        Item.ItemData.Accessory := TListBoxItemData.TAccessory.aCheckmark;
      Item.IsChecked := ARnd.NextFloat < 0.3;
      Item.Parent := LB;
    end;
  finally
    LB.EndUpdate;
  end;
  // New items are inflated (style prototype lookup) in idle time, 50 ms of wall clock per idle
  // message, and the list realigns all items when the queue is empty (FMX.Controls.pas:9071-9105,
  // FMX.ListBox.pas:2283-2284, :3223). Do it now instead of during the measurement; the content
  // inflater is the only TIdleMessage subscriber in FMX (FMX.Controls.pas:9062).
  for I := 0 to LB.Count - 1 do
    LB.ListItems[I].Inflate;
  TMessageManager.DefaultManager.SendMessage(Self, TIdleMessage.Create);
end;

function TListBoxScene.ScrollRange(const AList: TControl): Single;
var
  LB: TListBoxAccess;
begin
  LB := TListBoxAccess(AList);
  if LB.ContentLayout = nil then
    Exit(0);
  Result := Max(0, LB.ContentBounds.Height - LB.ContentLayout.Height);
end;

procedure TListBoxScene.ScrollTo(const AList: TControl; const APosition: Single);
var
  LB: TListBoxAccess;
begin
  LB := TListBoxAccess(AList);
  LB.ViewportPosition := TPointF.Create(0, LB.ContentBounds.Top + APosition);
  // TAniCalculations may postpone the change to its next timer tick; Realign applies it now
  // (TCustomScrollBox.DoRealign -> InternalAlign, FMX.Layouts.pas:2179-2196, :1843-1890).
  LB.Realign;
end;

procedure TListBoxScene.DoAdvance;
var
  Scene: IScene;
begin
  inherited;
  // A ViewportPosition change starts TAniCalculations, which marks the form as scrolling
  // (FMX.InertialMovement.pas:678-690, FMX.Layouts.pas:1346-1351, :2722-2726). On the GPU canvas that
  // stops adding new glyphs to the glyph atlas (FMX.Forms.pas:6381-6385, FMX.TextLayout.GPU.pas:2708);
  // this scene never stops scrolling, so uncached glyphs would cost a batch flush each for the whole
  // run. Clear the state: the atlas reaches the steady state of an app that has been used a while.
  if Supports(Form, IScene, Scene) then
    Scene.ChangeScrollingState(nil, False);
end;

{ TListViewScene }

class function TListViewScene.Name: string;
begin
  Result := 'listview';
end;

class function TListViewScene.Description: string;
begin
  Result := 'TListView ImageListItemBottomDetail, N items, 16 shared bitmaps, 1000 per list, scrolled';
end;

class function TListViewScene.DefaultN(const APreset: TBenchPreset): Integer;
begin
  // 2 / 10 / 16 lists. D2D throughput frame 2.3 / 9.4 / 14 ms at 1920x1080 logical px (measured
  // 2026-10-06 with --size=2880x1620 on the 150% monitor). 20 ms would need ~24 lists, too narrow
  // for the text.
  case APreset of
    TBenchPreset.Light: Result := 2000;
    TBenchPreset.Heavy: Result := 16000;
  else
    Result := 10000;
  end;
end;

destructor TListViewScene.Destroy;
var
  B: TBitmap;
begin
  // Items reference the thumbnails without owning them: free the lists first.
  FreeLists;
  for B in FThumbnails do
    B.Free;
  inherited;
end;

procedure TListViewScene.Setup;
var
  I: Integer;
begin
  SetLength(FThumbnails, ThumbnailCount);
  for I := 0 to ThumbnailCount - 1 do
    FThumbnails[I] := CreateThumbnail(I);
  inherited;
end;

function TListViewScene.CreateList: TControl;
var
  LV: TListView;
begin
  LV := TListView.Create(Form);
  LV.CanFocus := False;
  LV.ItemAppearance.ItemAppearance := TAppearanceNames.ImageListItemBottomDetail;
  LV.ItemAppearance.ItemHeight := ListViewItemHeight;
  Result := LV;
end;

procedure TListViewScene.FillList(const AList: TControl; const AFirstItem, ACount: Integer;
  var ARnd: TBenchRandom);
const
  Accessories: array[0..3] of TAccessoryType = (TAccessoryType.More, TAccessoryType.More,
    TAccessoryType.Detail, TAccessoryType.Checkmark);
var
  LV: TListView;
  Item: TListViewItem;
  I: Integer;
begin
  LV := TListView(AList);
  LV.BeginUpdate;
  try
    for I := 0 to ACount - 1 do
    begin
      Item := LV.Items.Add;
      Item.Text := RandomPhrase(ARnd, 2, 4, True);
      Item.Detail := Format('#%d  %s', [AFirstItem + I + 1, RandomPhrase(ARnd, 3, 8, False)]);
      Item.Accessory := Accessories[ARnd.RangeInt(0, High(Accessories))];
      Item.BitmapRef := FThumbnails[ARnd.RangeInt(0, ThumbnailCount - 1)];
    end;
  finally
    LV.EndUpdate;
  end;
end;

function TListViewScene.ScrollRange(const AList: TControl): Single;
var
  LV: TListView;
begin
  // As the private TListViewBase.GetMaxScrollViewPos (FMX.ListView.pas:2896-2899) for items of
  // equal height.
  LV := TListView(AList);
  Result := Max(Trunc(LV.SideSpace * 2 + LV.Items.Count * LV.ItemAppearance.ItemHeight - LV.Height), 0);
end;

procedure TListViewScene.ScrollTo(const AList: TControl; const APosition: Single);
begin
  TListView(AList).ScrollViewPos := APosition;
end;

initialization
  RegisterBenchScene(TListBoxScene);
  RegisterBenchScene(TListViewScene);
end.
