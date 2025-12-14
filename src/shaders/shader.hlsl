
struct CameraInfo {
  float4x4 screen_to_camera;
  float4x4 camera_to_world;
  float aperture_size;
  float focal_distance;
};

struct Material {
  float3 base_color;
  float roughness;
  float metallic;
  int texture_index;
  int normal_index; 
  float3 emission;
};

static float PI = 3.1415926536;

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

struct PointLight {
  float3 position;
  float3 color;
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
  uint num_point_lights;
  uint padding[2];
};
ConstantBuffer<FrameIndexCB> misc : register(b0, space8);
StructuredBuffer<uint> offset : register(t0, space9);
StructuredBuffer<float3> vertices : register(t1, space9);
StructuredBuffer<uint3> triangles : register(t2, space9);
StructuredBuffer<float2> global_uvs : register(t0, space10);           // Global UV coordinates (no padding)
StructuredBuffer<int> global_material_ids : register(t1, space10);     // Global material IDs (no padding)
StructuredBuffer<InstanceMetadata> instance_metadata : register(t0, space11);  // Per-instance metadata
StructuredBuffer<uint> global_indices : register(t2, space10);         // Global index buffer
Texture2D<float4> textures[64] : register(t0, space12);                          // Texture array (bindless)
SamplerState g_Sampler : register(s0, space13);
StructuredBuffer <PointLight> point_lights : register (t0, space14);
Texture2D<float4> normalmaps[64] : register(t0, space15); 
SamplerState normalmap_sampler : register(s0, space16);
Texture2D<float4>hdr_skybox: register(t0, space17);
SamplerState skybox_sampler : register(s0, space18);

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

float2 DirectionToUV(float3 dir) {
  float phi = atan2(dir.z, dir.x);
  float theta = acos(dir.y);
  return float2(phi / (2.0 * PI) + 0.5, theta / PI);
}

float3 SampleSkybox(float3 direction) {
  float2 uv = DirectionToUV(normalize(direction));
  return hdr_skybox.SampleLevel(skybox_sampler, uv, 0).rgb;
}

[shader("raygeneration")] void RayGenMain() {

  RayPayload payload;
  payload.color = float3(0, 0, 0);
  payload.hit = false;
  payload.instance_id = 0;
  uint2 pixel_coords = DispatchRaysIndex().xy;
  payload.seed = tea(pixel_coords.y * DispatchRaysDimensions().x + pixel_coords.x, misc.frame_index);
  payload.depth = 0;

  float2 pixel_center = (float2)DispatchRaysIndex() + float2(Rand(payload. seed), Rand(payload. seed));
  float2 uv = pixel_center / float2(DispatchRaysDimensions().xy);
  uv.y = 1.0 - uv.y;
  float2 d = uv * 2.0 - 1.0;
  float4 origin = mul(camera_info.camera_to_world, float4(0, 0, 0, 1));
  float4 target = mul(camera_info.screen_to_camera, float4(d, 1, 1));
  float4 direction = mul(camera_info.camera_to_world, float4(target.xyz, 0));
  float3 ray_direction = normalize(direction.xyz);

  float3 focal_point = origin.xyz + ray_direction * camera_info.focal_distance;
  
  float theta = Rand(payload.seed) * 2.0 * PI;
  float r = sqrt(Rand(payload.seed)) * camera_info.aperture_size;
  float2 aperture_offset = float2(cos(theta), sin(theta)) * r;
  

  float3 camera_right = normalize(mul(camera_info.camera_to_world, float4(1, 0, 0, 0)).xyz);
  float3 camera_up = normalize(mul(camera_info.camera_to_world, float4(0, 1, 0, 0)).xyz);

  

  float3 ray_origin = origin.xyz + aperture_offset.x * camera_right + aperture_offset.y * camera_up;
  //if (camera_info. focal_distance == 0) while(1);
  float3 new_ray_direction = normalize(focal_point - ray_origin);

  


  float t_min = 1e-3;
  float t_max = 1e4;

  RayDesc ray;
  ray.Origin = ray_origin;
  ray.Direction = new_ray_direction;
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
  payload.color = SampleSkybox(WorldRayDirection());
  payload.hit = false;
  payload.instance_id = 0xFFFFFFFF;
// Invalid ID for miss
}


struct ShadowPayload { bool blocked; };
[shader("miss")] void ShadowMiss(inout ShadowPayload payload) {
  payload. blocked = false;
}


bool IsLightVisible(float3 origin, float3 dir, float dist_to_light) {
  ShadowPayload sp;
  sp.blocked = false;

  RayDesc shadow;
  shadow.Origin = origin;
  shadow.Direction = dir;
  shadow.TMin = 1e-3;
  shadow.TMax = dist_to_light;

  TraceRay(
      as,
      RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH |
      RAY_FLAG_SKIP_CLOSEST_HIT_SHADER |
      RAY_FLAG_FORCE_OPAQUE,
      0xFF,
      0, 0, 1,
      shadow,
      sp
  );

  return ! sp. blocked;
}

static float p = 0.2;


float sqr(float x) { return x * x; }
float3 calcF0(Material mat) {
  return lerp(float3 (0.04, 0.04, 0.04), mat. base_color, mat. metallic);
}
float calcD(float alpha, float n_h) {
  return sqr(alpha) / (PI * sqr(sqr(n_h) * sqr(alpha) + (1 - sqr(n_h))));
}
float3 BRDF(in Material mat, in float3 oi, in float3 oo, in float3 n) {
  float3 h = normalize(oi + oo);
  float n_oi = dot(n, oi), n_oo = dot(n, oo), n_h = dot(n, h);
  if (n_oi <= 0.0f || n_oo <= 0.0f) return float3 (0.0, 0.0, 0.0);
  float3 F0 = calcF0(mat);
  float3 F = F0 + (float3 (1.0, 1.0, 1.0) - F0) * pow(clamp(1 - dot(oo, h), 0.0, 1.0), 5);
  float alpha = sqr(mat. roughness);
  float D = calcD(alpha, n_h);
  float k = sqr(alpha + 1) / 8;
  float G = n_oi / lerp(n_oi, 1.0, k) * n_oo / lerp(n_oo, 1.0, k);
  float3 fs = (1 - mat. metallic) / PI * mat. base_color * (float3(1.0, 1.0, 1.0) - F);
  return fs + F * D * G / (4 * n_oi * n_oo + 1e-7);
}
float luminance(float3 c) {
  return 0.2126 * c. r + 0.7152 * c. g + 0.0722 * c. b;
}

Material getMaterial(in uint instance_id, in uint primitive_id, in BuiltInTriangleIntersectionAttributes attr, inout float3 N, in float3 p0, in float3 p1, in float3 p2) {
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
    
    // Sample base color texture
    float4 texture_color = textures[mat.texture_index].SampleLevel(g_Sampler, uv, 0);
    mat.base_color = texture_color.rgb;
    
    // Sample normal map
    if(mat.normal_index != -1) {
        float3 normalMapSample = normalmaps[mat.normal_index].SampleLevel(normalmap_sampler, uv, 0).xyz;
        
        // Convert from [0,1] to [-1,1] range
        float3 tangentNormal = normalMapSample * 2.0 - 1.0;

        float2 duv1 = uvx1 - uvx0, duv2 = uvx2 - uvx0;
        float3 dp1  = p1 - p0,    dp2  = p2 - p0;
        float r = 1.0 / (duv1.x * duv2.y - duv1.y * duv2.x + 1e-8);
        float3 T = normalize((dp1 * duv2.y - dp2 * duv1.y) * r);
        float3 B = normalize((dp2 * duv1.x - dp1 * duv2.x) * r);
        
        // Build TBN matrix (tangent space to world space)
        float3x3 TBN = float3x3(T, B, N);
        
        // Transform normal from tangent space to world space
        N = normalize(mul(tangentNormal, TBN));
        
        // Ensure normal faces the correct direction
        if (dot(N, -WorldRayDirection()) < 0.0)
          N = -N;

    }
  }
  
  return mat;
}

#define assert(cond) if (!(cond)) { while (1); }

[shader("closesthit")] void ClosestHitMain(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attr) {
  uint material_id = InstanceID(), primitive_id = PrimitiveIndex();
  
  // Calculate normal
  uint id = offset[material_id] + primitive_id;
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
  
  // Load material (this will also update N with normal map if available)
  Material mat = getMaterial(material_id, primitive_id, attr, N, p0, p1, p2);
  mat. roughness = clamp(mat. roughness, 1e-2, 1.0);
  if (Rand(payload. seed) < p) {
    payload. hit = true;
    payload. instance_id = material_id;
    payload. color = mat. emission;
    return ;
  }
  if (payload. depth > 20) {
    payload. color = float3 (0.0, 0.0, 0.0);
    return ;
  }
  float3x3 M = transpose(float3x3 (T, B, N));
  // Sample a direction
  // float phi = Rand(payload. seed) * 2 * PI, cosTheta = Rand(payload. seed), sinTheta = sqrt(1 - sqr(cosTheta));
  // float3 inDir = sinTheta * (cos(phi) * T + sin(phi) * B) + cosTheta * N;
  // float3 outDir = - WorldRayDirection();
  // float P = 1 / (2 * PI);
  float3 outDir = - WorldRayDirection(), inDir;
  float3 F0 = calcF0(mat);
  float p_mix = clamp(luminance(F0) + (1 - mat. roughness) * 0.1, 0.05, 0.95);
  float alpha = sqr(mat. roughness), alpha2 = sqr(alpha);
  if (Rand(payload. seed) <= p_mix) {
    do {
      float phi = Rand(payload. seed) * 2 * PI, xi = Rand(payload. seed), cosTheta = sqrt(xi / ((1 - xi) * alpha2 + xi)), sinTheta = cosTheta >= 1.0 ? 0 : sqrt(1 - sqr(cosTheta));
      float3 h = mul(M, float3 (sinTheta * cos(phi), sinTheta * sin(phi), cosTheta));
      inDir = h * dot(outDir, h) * 2 - outDir;
    } while (dot(N, inDir) < 0);
  } else {
    float r = sqrt(Rand(payload. seed)), phi = Rand(payload. seed) * 2 * PI;
    inDir = mul(M, float3 (r * cos(phi), r * sin(phi), sqrt(1 - sqr(r))));
  }
  float3 h = normalize(inDir + outDir);
  float n_h = dot(N, h);
  float pd = dot(N, inDir) / PI, ps = calcD(alpha, n_h) * n_h / (4 * dot(outDir, h));
  float P = p_mix * ps + (1 - p_mix) * pd;

  float3 light_contribution = float3 (0.0, 0.0, 0.0);
  float3 hitpos = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();
  for (uint i=0; i<misc.num_point_lights; i++) {
    float3 lightDir = point_lights[i]. position - hitpos;
    float dis = length(lightDir);
    if (dis < 1e-4) continue;
    lightDir /= dis;
    if (dot(N, lightDir) <= 0.0f) continue;
    if (IsLightVisible(hitpos + 1e-4 * inDir, lightDir, dis - 1e-4)) {
      light_contribution += BRDF(mat, lightDir, outDir, N) * dot(N, lightDir) * point_lights[i]. color / sqr(dis);
    }
  }

  // Bounce the ray
  RayDesc ray;
  ray. Origin = hitpos + 1e-4 * inDir;
  ray. Direction = inDir;
  ray. TMin = 1e-3;
  ray. TMax = 1e4;
  payload. depth ++;
  TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);
  // Calculate color
  payload. color = payload. color * BRDF(mat, inDir, outDir, N) * dot(N, inDir) / P / (1 - p) + mat. emission + light_contribution;
  payload. hit = true;
  payload. instance_id = InstanceID();
}