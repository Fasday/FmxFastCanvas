unit FastCanvas.Service;

{ Makes our canvas and 3D context classes the default ones.

  TCanvasManager.GetDefaultCanvas asks IFMXCanvasService to register the canvas classes on first use
  and then takes the first default class (FMX.Graphics.pas:6049-6096); TContextManager does the same with
  IFMXContextService (FMX.Types3D.pas:4932-4956). The services are wrapped, as FMX.Skia.Canvas does
  (FMX.Skia.Canvas.pas:4566-4571): our class is registered first, then the platform classes as usual,
  so printing and fallbacks keep working.

  UnregisterCanvasClasses / UnregisterContextClasses are called by TCanvasManager.UnInitialize /
  TContextManager.UnInitialize from FinalizeForms, after all forms are freed (FMX.Forms.pas:8506-8521),
  which runs in the finalization of FMX.Platform (FMX.Platform.pas:757), i.e. after the finalization of
  the canvas units. Shared device resources are therefore released from AShutdown, not from a unit
  finalization.

  Call the Install* procedures before Application.Initialize. }

interface

uses
  System.SysUtils, FMX.Graphics, FMX.Types3D;

procedure InstallCanvasService(const ACanvasClass: TCanvasClass; const AShutdown: TProc = nil);
procedure InstallContextService(const AContextClass: TContextClass; const AShutdown: TProc = nil);

implementation

uses
  FMX.Platform;

type
  TFastCanvasService = class(TInterfacedObject, IFMXCanvasService)
  private
    FCurrent: IFMXCanvasService;
    FCanvasClass: TCanvasClass;
    FShutdown: TProc;
  public
    constructor Create(const ACurrent: IFMXCanvasService; const ACanvasClass: TCanvasClass; const AShutdown: TProc);
    procedure RegisterCanvasClasses;
    procedure UnregisterCanvasClasses;
  end;

  TFastContextService = class(TInterfacedObject, IFMXContextService)
  private
    FCurrent: IFMXContextService;
    FContextClass: TContextClass;
    FShutdown: TProc;
  public
    constructor Create(const ACurrent: IFMXContextService; const AContextClass: TContextClass;
      const AShutdown: TProc);
    procedure RegisterContextClasses;
    procedure UnregisterContextClasses;
  end;

{ TFastCanvasService }

constructor TFastCanvasService.Create(const ACurrent: IFMXCanvasService; const ACanvasClass: TCanvasClass;
  const AShutdown: TProc);
begin
  inherited Create;
  FCurrent := ACurrent;
  FCanvasClass := ACanvasClass;
  FShutdown := AShutdown;
end;

procedure TFastCanvasService.RegisterCanvasClasses;
begin
  TCanvasManager.RegisterCanvas(FCanvasClass, True, False);
  if FCurrent <> nil then
    FCurrent.RegisterCanvasClasses;
end;

procedure TFastCanvasService.UnregisterCanvasClasses;
var
  Shutdown: TProc;
begin
  if FCurrent <> nil then
    FCurrent.UnregisterCanvasClasses;
  Shutdown := FShutdown;
  FShutdown := nil;
  if Assigned(Shutdown) then
    Shutdown();
end;

{ TFastContextService }

constructor TFastContextService.Create(const ACurrent: IFMXContextService; const AContextClass: TContextClass;
  const AShutdown: TProc);
begin
  inherited Create;
  FCurrent := ACurrent;
  FContextClass := AContextClass;
  FShutdown := AShutdown;
end;

procedure TFastContextService.RegisterContextClasses;
begin
  TContextManager.RegisterContext(FContextClass, True);
  if FCurrent <> nil then
    FCurrent.RegisterContextClasses;
end;

procedure TFastContextService.UnregisterContextClasses;
var
  Shutdown: TProc;
begin
  if FCurrent <> nil then
    FCurrent.UnregisterContextClasses;
  Shutdown := FShutdown;
  FShutdown := nil;
  if Assigned(Shutdown) then
    Shutdown();
end;

procedure InstallCanvasService(const ACanvasClass: TCanvasClass; const AShutdown: TProc);
var
  Current: IFMXCanvasService;
begin
  if not TPlatformServices.Current.SupportsPlatformService(IFMXCanvasService, Current) then
    Current := nil;
  TPlatformServices.Current.RemovePlatformService(IFMXCanvasService);
  TPlatformServices.Current.AddPlatformService(IFMXCanvasService,
    TFastCanvasService.Create(Current, ACanvasClass, AShutdown));
end;

procedure InstallContextService(const AContextClass: TContextClass; const AShutdown: TProc);
var
  Current: IFMXContextService;
begin
  if not TPlatformServices.Current.SupportsPlatformService(IFMXContextService, Current) then
    Current := nil;
  TPlatformServices.Current.RemovePlatformService(IFMXContextService);
  TPlatformServices.Current.AddPlatformService(IFMXContextService,
    TFastContextService.Create(Current, AContextClass, AShutdown));
end;

end.
