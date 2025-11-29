
struct CameraInfo {
  float4x4 screen_to_camera;
  float4x4 camera_to_world;
};

struct Material {
  float3 base_color;
  float roughness;
  float metallic;
  int texture_index;
  float3 emission;
};

struct InstanceMetadata {
  int uv_offset;          // Offset in global UV buffer (-1 if no UV)
  int material_id_offset; // Offset in global material ID buffer (or direct material index)
  int has_uv;             // Boolean flag (0 or 1)
  int has_material_ids;   // Boolean flag (0 or 1)
  int vertex_count;       // Number of vertices (0 if no UV)
  int triangle_count;     // Number of triangles (0 if no material IDs)
  int index_offset;       // Offset in global index buffer
  int padding[1];         // Align to 32 bytes (reduced from 2 to 1)
};

struct HoverInfo {
  int hovered_entity_id;
};

RaytracingAccelerationStructure as : register(t0, space0);
RWTexture2D<float4> output : register(u0, space1);
ConstantBuffer<CameraInfo> camera_info : register(b0, space2);
StructuredBuffer<Material> materials : register(t0, space3);
ConstantBuffer<HoverInfo> hover_info : register(b0, space4);
RWTexture2D<int> entity_id_output : register(u0, space5);
RWTexture2D<float4> accumulated_color : register(u0, space6);
RWTexture2D<int> accumulated_samples : register(u0, space7);
struct FrameIndexCB {
  uint frame_index;
  uint padding[3];
};
ConstantBuffer<FrameIndexCB> frame_index : register(b0, space8);
StructuredBuffer<uint> offset : register(t0, space9);
StructuredBuffer<float3> vertices : register(t1, space9);
StructuredBuffer<uint3> triangles : register(t2, space9);
StructuredBuffer<float2> global_uvs : register(t0, space10);           // Global UV coordinates (no padding)
StructuredBuffer<int> global_material_ids : register(t1, space10);     // Global material IDs (no padding)
StructuredBuffer<InstanceMetadata> instance_metadata : register(t0, space11);  // Per-instance metadata
StructuredBuffer<uint> global_indices : register(t2, space10);         // Global index buffer
Texture2D<float4> textures[64] : register(t0, space12);                          // Texture array (bindless)
SamplerState g_Sampler : register(s0, space13);

struct RayPayload {
  float3 color;
  bool hit;
  uint instance_id;
  uint seed;
  uint depth;
};

float Rand(inout uint state) {
  state ^= state << 13;
  state ^= state >> 17;
  state ^= state << 5;
  return state * 2.3283064365386962890625e-10;
}

uint tea(uint val0, uint val1) {
  uint v0 = val0; uint v1 = val1; uint s0 = 0;
  for(uint n = 0; n < 16; n++) {
    s0 += 0x9e3779b9;
    v0 += ((v1 << 4) + 0xa341316c) ^ (v1 + s0) ^ ((v1 >> 5) + 0xc8013ea4);
    v1 += ((v0 << 4) + 0xad90777d) ^ (v0 + s0) ^ ((v0 >> 5) + 0x7e95761e);
  }
  return v0;
}

[shader("raygeneration")] void RayGenMain() {

  RayPayload payload;
  payload.color = float3(0, 0, 0);
  payload.hit = false;
  payload.instance_id = 0;
  uint2 pixel_coords = DispatchRaysIndex().xy;
  payload.seed = tea(pixel_coords.y * DispatchRaysDimensions().x + pixel_coords.x, frame_index.frame_index);
  payload.depth = 0;

  float2 pixel_center = (float2)DispatchRaysIndex() + float2(Rand(payload. seed), Rand(payload. seed));
  float2 uv = pixel_center / float2(DispatchRaysDimensions().xy);
  uv.y = 1.0 - uv.y;
  float2 d = uv * 2.0 - 1.0;
  float4 origin = mul(camera_info.camera_to_world, float4(0, 0, 0, 1));
  float4 target = mul(camera_info.screen_to_camera, float4(d, 1, 1));
  float4 direction = mul(camera_info.camera_to_world, float4(target.xyz, 0));

  float t_min = 0.001;
  float t_max = 10000.0;

  RayDesc ray;
  ray.Origin = origin.xyz;
  ray.Direction = normalize(direction.xyz);
  ray.TMin = t_min;
  ray.TMax = t_max;

  TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);

  // uint2 pixel_coords = DispatchRaysIndex().xy;
  
  // Write to immediate output (for camera movement mode)
  output[pixel_coords] = float4(payload.color, 1);
  
  // Write entity ID to the ID buffer
  // If no hit, write -1; otherwise write the instance ID
  entity_id_output[pixel_coords] = payload.hit ? (int)payload.instance_id : -1;
  
  // Accumulate color for progressive rendering (when camera is stationary)
  float4 prev_color = accumulated_color[pixel_coords];
  int prev_samples = accumulated_samples[pixel_coords];
  
  accumulated_color[pixel_coords] = prev_color + float4(payload.color, 1);
  accumulated_samples[pixel_coords] = prev_samples + 1;
}

[shader("miss")] void MissMain(inout RayPayload payload) {
  // Sky gradient
  float t = 0.5 * (normalize(WorldRayDirection()).y + 1.0);
  payload.color = lerp(float3(0.0, 0.0, 0.0), float3(0.1, 0.15, 0.2), t);
  payload.hit = false;
  payload.instance_id = 0xFFFFFFFF; // Invalid ID for miss
}

static float p = 0.2;
static float PI = 3.1415926536;

float sqr(float x) { return x * x; }
float3 BRDF(in Material mat, in float3 oi, in float3 oo, in float3 n) {
  float3 h = normalize(oi + oo);
  float n_oi = dot(n, oi), n_oo = dot(n, oo), n_h = dot(n, h);
  if (n_oi <= 0.0f || n_oo <= 0.0f) return float3 (0.0, 0.0, 0.0);
  float3 F0 = lerp(float3 (0.04, 0.04, 0.04), mat. base_color, mat. metallic);
  float3 F = F0 + (float3 (1.0, 1.0, 1.0) - F0) * pow(1 - dot(oo, h), 5);
  float alpha = sqr(mat. roughness);
  float D = sqr(alpha) / (PI * sqr(sqr(n_h) * (sqr(alpha) - 1) + 1) + 1e-7);
  float k = sqr(alpha + 1) / 8;
  float G = n_oi / lerp(n_oi, 1.0, k) * n_oo / lerp(n_oo, 1.0, k);
  float3 fs = (1 - mat. metallic) / PI * mat. base_color * (float3(1.0, 1.0, 1.0) - F);
  return fs + F * D * G / (4 * n_oi * n_oo + 1e-7);
}

Material getMaterial(in uint instance_id, in uint primitive_id, in BuiltInTriangleIntersectionAttributes attr) {
  // Load instance metadata
  InstanceMetadata metadata = instance_metadata[instance_id];
  
  // Get material ID based on whether this instance has material IDs
  int material_id;
  if (metadata.has_material_ids == 1) {
    // Instance has per-triangle material IDs - look up in global buffer
    int mat_offset = metadata.material_id_offset;
    material_id = global_material_ids[mat_offset + primitive_id];
  } else {
    // Instance uses single material - material_id_offset IS the material index
    material_id = metadata.material_id_offset;
  }
  
  // Load material
  Material mat = materials[material_id];
  if(mat.texture_index != -1) {
    float2 bc = attr.barycentrics;
    int uv_offset = instance_metadata[instance_id].uv_offset;
    int index_offset = instance_metadata[instance_id].index_offset;
    int idx0 = global_indices[index_offset + primitive_id * 3 + 0];
    int idx1 = global_indices[index_offset + primitive_id * 3 + 1];
    int idx2 = global_indices[index_offset + primitive_id * 3 + 2];
    float2 uvx0 = global_uvs[uv_offset + idx0];
    float2 uvx1 = global_uvs[uv_offset + idx1];
    float2 uvx2 = global_uvs[uv_offset + idx2];
    float2 uv = (1.0 - bc.x - bc.y) * uvx0 + bc.x * uvx1 + bc.y * uvx2; 
    uv.y = 1 - uv.y;
    float4 texture_color = textures[mat.texture_index].SampleLevel(g_Sampler, uv, 0);
    mat.base_color = texture_color.rgb; 
  }
  return mat;
}

[shader("closesthit")] void ClosestHitMain(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attr) {
  uint material_idx = InstanceID();
  if (Rand(payload. seed) < p) {
    payload. hit = true;
    payload. instance_id = material_idx;
    payload. color = materials[material_idx]. emission;
    return ;
  }
  if (payload. depth > 20) {
    payload. color = float3 (0.0, 0.0, 0.0);
    return ;
  }
  // Calculate normal
  uint primitive_id = PrimitiveIndex();
  uint id = offset[material_idx] + primitive_id;
  uint3 vid = triangles[id];
  float3 p0 = vertices[vid.x];
  float3 p1 = vertices[vid.y];
  float3 p2 = vertices[vid.z];
  float3 N = normalize(cross(p1 - p0, p2 - p0));
  // N = normalize(mul((float3x3) ObjectToWorld3x4(), N));
  if (dot(WorldRayDirection(), N) > 0.0)
    N = - N;
  float3 B = normalize(p1 - p0);
  if (abs(dot(N, B)) > 1e-6)
    B = normalize(B - dot(N, B) * N);
  float3 T = cross(N, B);
  // Sample a direction
  float phi = Rand(payload. seed) * 2 * PI, cosTheta = Rand(payload. seed), sinTheta = sqrt(1 - sqr(cosTheta));
  float3 inDir = sinTheta * (cos(phi) * B + sin(phi) * T) + cosTheta * N;
  float3 outDir = WorldRayDirection();
  // Bounce the ray
  RayDesc ray;
  ray. Origin = WorldRayOrigin() + WorldRayDirection() * RayTCurrent() + 1e-4 * inDir;
  ray. Direction = inDir;
  ray. TMin = 1e-3;
  ray. TMax = 1e4;
  payload. depth ++;
  TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);
  // Load Material
  Material mat = getMaterial(material_idx, primitive_id, attr);
  payload. color = (payload. color * BRDF(mat, inDir, - outDir, N) * cosTheta * 2 * PI) / (1 - p) + materials[material_idx]. emission;
  payload. hit = true;
  payload. instance_id = InstanceID();
}