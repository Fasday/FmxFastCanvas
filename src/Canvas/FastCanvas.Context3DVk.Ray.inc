{ Ray-traced effects of the Vulkan 3D context (included by FastCanvas.Context3DVk). }

function RaySupported: Boolean;
begin
  Result := False;
end;

procedure RayClear;
begin
end;

procedure RayDrop(const AContext: TGpuVkContext);
begin
end;

procedure RayAfterDraw(const AContext: TGpuVkContext; const ADraw: PCmdDraw; const AVertexBuffer: TVkBuffer;
  const AVertexOffset: UInt64; const AIndexBuffer: TVkBuffer; const AIndexOffset: UInt64);
begin
end;

procedure TFastContext3DVk.RecordRayObject(const AVertices, AIndices: Pointer; const AVertexSize, AVertexCount,
  AIndexSize, AIndexCount, APosition, ANormal, ATexCoord: Integer);
begin
end;

procedure TFastContext3DVk.RecordRay;
begin
end;
