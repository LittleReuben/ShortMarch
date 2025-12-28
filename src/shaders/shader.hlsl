
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
  float3 transmission;
  float alpha;
  float3 volume_emission;
  float volume_density;
  float3 volume_scatter;
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
struct MiscBlock {
  uint frame_index;
  uint num_point_lights;
  uint num_emissive_tris;
  uint padding[5];
};
ConstantBuffer<MiscBlock> misc : register(b0, space8);
StructuredBuffer<uint> offset : register(t0, space9);
StructuredBuffer<float3> vertices : register(t1, space9);
StructuredBuffer<uint3> triangles : register(t2, space9);
StructuredBuffer<float2> global_uvs : register(t0, space10);           // Global UV coordinates (no padding)
StructuredBuffer<int> global_material_ids : register(t1, space10);     // Global material IDs (no padding)
StructuredBuffer<InstanceMetadata> instance_metadata : register(t0, space11);  // Per-instance metadata
StructuredBuffer<uint> global_indices : register(t2, space10);         // Global index buffer
Texture2D<float4> textures[256] : register(t0, space12);                          // Texture array (bindless)
SamplerState g_Sampler : register(s0, space13);
StructuredBuffer <PointLight> point_lights : register (t0, space14);
Texture2D<float4> normalmaps[256] : register(t0, space15); 
SamplerState normalmap_sampler : register(s0, space16);
Texture2D<float4>hdr_skybox: register(t0, space17);
SamplerState skybox_sampler : register(s0, space18);
StructuredBuffer<uint2> emissive_tris : register(t0, space19);

struct RayPayload {
  float3 color;
  float3 coef; // throughput, 当前的 BRDF & IS 项系数
  bool hit;
  uint instance_id;
  uint seed;
  bool bounce; // 如果要递归就设为 1, 如果结束递归再设为 0
  bool count_emission; // 如果从头到现在都是透射就是 1, 否则就是 0
  float3 nxt_origin;
  float3 nxt_direction;
  int current_medium_id;
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

float luminance(float3 c) ;

void Calculate(inout RayPayload payload) {
  uint depth = 0;
  do {
    RayDesc ray;
    ray. Origin = payload. nxt_origin;
    ray. Direction = payload. nxt_direction;
    ray. TMin = 1e-3;
    ray. TMax = 1e4;
    TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);
    if (luminance(payload. coef) < 1e-3) break;
    if (++ depth > 50) break;
  } while (payload. bounce);
}

[shader("raygeneration")] void RayGenMain() {

  RayPayload payload;
  payload. color = float3(0, 0, 0);
  payload. coef = float3(1, 1, 1);
  payload. hit = false;
  payload. instance_id = 0;
  uint2 pixel_coords = DispatchRaysIndex().xy;
  payload. seed = tea(pixel_coords.y * DispatchRaysDimensions().x + pixel_coords.x, misc.frame_index);
  payload. bounce = 0; // 方便 instance_id 和 hit
  payload. count_emission = 1;
  payload. current_medium_id = -1;

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

  
  payload. nxt_origin = ray_origin;
  payload. nxt_direction = new_ray_direction;
  Calculate(payload);
  
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
  if (! payload. bounce) {
    payload.hit = false;
    payload.instance_id = 0xFFFFFFFF;
  }
  payload.color += payload. coef * SampleSkybox(WorldRayDirection()) * float3(0.5f, 0.5f, 0.5f);
  payload. bounce = 0;
}


static float p = 0.1;


float sqr(float x) { return x * x; }
float3 calcF0(Material mat) {
  return lerp(float3 (0.04, 0.04, 0.04), mat. base_color, mat. metallic);
}
float3 FresnelSchlick(float3 F0, float3 V_N) {
  return F0 + (float3 (1.0, 1.0, 1.0) - F0) * pow(clamp(1 - V_N, 0.0, 1.0), 5);
}
float calcD(float alpha, float n_h) {
  return sqr(alpha) / (PI * sqr(sqr(n_h) * sqr(alpha) + (1 - sqr(n_h))));
}
float3 BRDF(in Material mat, in float3 oi, in float3 oo, in float3 n, out float3 fs, out float3 fd) {
  float3 h = normalize(oi + oo);
  float n_oi = dot(n, oi), n_oo = dot(n, oo), n_h = dot(n, h);
  if (n_oi <= 0.0f || n_oo <= 0.0f) return fs = fd = float3 (0.0, 0.0, 0.0);
  float3 F0 = calcF0(mat);
  float3 F = FresnelSchlick(F0, dot(oo, h));
  float alpha = sqr(mat. roughness);
  float D = calcD(alpha, n_h);
  float k = sqr(alpha + 1) / 8;
  float G = n_oi / lerp(n_oi, 1.0, k) * n_oo / lerp(n_oo, 1.0, k);
  fs = F * D * G / (4 * n_oi * n_oo + 1e-7);
  fd = (1 - mat. metallic) / PI * mat. base_color * (1 - F);
  return fs + fd;
}
float luminance(float3 c) {
  return 0.2126 * c. r + 0.7152 * c. g + 0.0722 * c. b;
}

// Isotropic phase function for volume scattering
// Returns the probability density for scattering in any direction (constant for isotropic)
// 各向同性相位函数：在所有方向上均匀散射，返回常数概率密度 1/(4π)
float IsotropicPhaseFunction() {
  return 1.0 / (4.0 * PI);
}

// Sample a random direction on the unit sphere (isotropic scattering)
// 在单位球面上均匀采样一个随机方向（各向同性散射）
// 使用均匀分布采样球面：cosθ ∈ [-1,1], φ ∈ [0,2π]
float3 SampleIsotropicDirection(inout uint seed) {
  float cos_theta = 2.0 * Rand(seed) - 1.0;  // [-1, 1] 均匀分布
  float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
  float phi = 2.0 * PI * Rand(seed);
  
  return float3(
    sin_theta * cos(phi),
    sin_theta * sin(phi),
    cos_theta
  );
}

// Sample a volume scattering event along a ray segment
// 沿光线段采样体积散射事件
// 返回值：
//   - scattered: 是否发生了散射事件
//   - scatter_distance: 散射发生的距离（如果发生）
//   - new_direction: 散射后的新方向（如果发生）
//   - throughput: 光线通量衰减系数
bool SampleVolumeScattering(
    int mat_id,
    float t_max,
    inout uint seed,
    out float scatter_distance,
    out float3 new_direction,
    out float3 throughput
) {
  // 默认值：无散射，完全透射
  scatter_distance = t_max;
  new_direction = float3(0, 0, 0);
  throughput = float3(1, 1, 1);
  
  // 如果不在介质中，直接返回
  if (mat_id < 0) {
    return false;
  }
  
  Material mat = materials[mat_id];
  
  // 检查材质是否有体积属性
  if (mat.volume_density <= 0.0) {
    return false;
  }
  
  // 计算散射和吸收系数
  // σ_s = 散射系数 = density × albedo
  // σ_a = 吸收系数 = density × (1 - albedo)
  // σ_t = 消光系数 = σ_s + σ_a = density
  float3 sigma_s = mat.volume_density * mat.volume_scatter;  // 散射系数
  float3 sigma_a = mat.volume_density * (1.0 - mat.volume_scatter);  // 吸收系数
  float sigma_t = mat.volume_density;  // 总消光系数
  
  // 使用指数分布采样散射距离
  // 概率密度函数: p(t) = σ_t * exp(-σ_t * t)
  // 累积分布函数: P(t) = 1 - exp(-σ_t * t)
  // 逆变换采样: t = -ln(1 - ξ) / σ_t，其中 ξ ~ U(0,1)
  float xi = Rand(seed);
  float sampled_t = -log(max(1e-10, 1.0 - xi)) / sigma_t;
  
  // 检查散射事件是否在光线段内发生
  if (sampled_t >= t_max) {
    // 散射事件在光线段之外，光线穿过整个介质段而不散射
    // 计算透射率 = exp(-σ_t * distance)
    throughput = exp(-sigma_t * t_max);
    return false;
  }
  
  // 散射事件发生！
  scatter_distance = sampled_t;
  
  // 使用各向同性相位函数采样新的散射方向
  new_direction = SampleIsotropicDirection(seed);
  
  // 计算通量（throughput）
  // throughput = exp(-σ_t * t) × (σ_s / σ_t)
  // 其中：
  //   - exp(-σ_t * t): 到达散射点的衰减
  //   - σ_s: 散射系数（散射贡献）
  //   - 除以 σ_t 是因为采样使用了 σ_t 的概率密度
  float3 transmittance_to_scatter = exp(-sigma_t * sampled_t);
  throughput = transmittance_to_scatter * (sigma_s / max(1e-10, sigma_t));
  
  return true;
}

// Sample volumetric contribution along a ray segment (for direct transmittance only)
// 仅计算光线穿过体积时的直接透射和发光贡献（不包括散射事件）
// 这个函数用于计算光线到达表面之前经过介质的衰减和发光
// Returns both emission and transmittance for the medium
// mat_id: Material ID of the medium
// t_end: Distance traveled through the medium
void SampleVolumeContribution(int mat_id, float t_end, out float3 emission, out float3 transmittance) {
  // Default values: no emission, full transmittance
  emission = float3(0.0, 0.0, 0.0);
  transmittance = float3(1.0, 1.0, 1.0);
  
  // If no medium or invalid material ID, return defaults
  if (mat_id < 0) {
    return;
  }
  
  Material mat = materials[mat_id];
  
  // Check if this material has volumetric properties
  if (mat.volume_density <= 0.0) {
    return;
  }
  
  float distance = t_end;
  float optical_depth = mat.volume_density * distance;
  
  // Beer-Lambert law: transmittance = exp(-extinction * distance)
  // Extinction coefficient = density (total attenuation from both scattering and absorption)
  // 使用 Beer-Lambert 定律计算透射率：transmittance = exp(-σ_t × distance)
  // 消光系数 σ_t = volume_density（包含散射和吸收的总衰减）
  float extinction = mat.volume_density;
  transmittance = exp(-extinction * distance);
  
  // Volumetric emission (attenuated by self-absorption)
  // 体积发光贡献（被自吸收衰减）
  // 沿路径积分：∫ emission × exp(-σ_t × t) dt = emission × (1 - exp(-σ_t × distance)) / σ_t
  // 简化为：emission × (1 - transmittance)
  emission = mat.volume_emission * (1.0 - exp(-optical_depth));
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
    mat.alpha = texture_color.a;

    // float3 tmp = float3(1.0, 1.0, 1.0)-mat.transmission;
    // tmp = tmp * texture_color.a;
    // mat.transmission = float3(1.0, 1.0, 1.0)-tmp;
    
    
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

void getOrthonormalBasis(float3 n, out float3 t, out float3 b) {
  if (n.z < -0.999999f) { // 特殊情况处理
    t = float3 (0.0, -1.0, 0.0);
    b = float3 (-1.0, 0.0, 0.0);
    return;
  }
  float a = 1.0 / (1.0 + n.z);
  float d = -n.x * n.y * a;
  t = normalize(float3 (1.0 - n.x * n.x * a, d, -n.x));
  b = normalize(float3 (d, 1.0 - n.y * n.y * a, -n.y));
}

#define assert(cond) if (!(cond)) { while (1); }

enum rayComponent {
  SPECULAR, DIFFUSE, TRANSMISSIVE
} ;

struct ShadowPayload { float3 attenuation; };
[shader("anyhit")] void ShadowHit(inout ShadowPayload payload, in BuiltInTriangleIntersectionAttributes attr) {
  uint instance_id = InstanceID(), primitive_id = PrimitiveIndex();
  float3 hitpos = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();
  uint id = offset[instance_id] + primitive_id;
  uint3 vid = triangles[id];
  float3 p0 = vertices[vid.x];
  float3 p1 = vertices[vid.y];
  float3 p2 = vertices[vid.z];
  float3 N = normalize(cross(p1 - p0, p2 - p0));
  if (dot(WorldRayDirection(), N) > 0.0) N = - N;
  Material mat = getMaterial(instance_id, primitive_id, attr, N, p0, p1, p2);
  mat. roughness = clamp(mat. roughness, 1e-2, 1.0);
  float3 F = FresnelSchlick(calcF0(mat), dot(N, - WorldRayDirection()));
  payload. attenuation *= (1 - mat. alpha) * float3 (1.0, 1.0, 1.0) + mat. alpha * (1 - mat. metallic) * mat. transmission * (1 - F);
  if (luminance(payload. attenuation) < 1e-3) AcceptHitAndEndSearch();
  else IgnoreHit();
}
[shader("miss")] void ShadowMiss(inout ShadowPayload payload) {}
[shader("closesthit")] void ShadowClosestHit(inout ShadowPayload payload, in BuiltInTriangleIntersectionAttributes attr) {}

float3 CalcLightAttenuation(float3 origin, float3 dir, float dist_to_light) {
  ShadowPayload sp;
  sp. attenuation = float3 (1.0, 1.0, 1.0);
  RayDesc shadow;
  shadow.Origin = origin;
  shadow.Direction = dir;
  shadow.TMin = 1e-4;
  shadow.TMax = dist_to_light;
  TraceRay(as,
      RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
      0xFF, 1, 1, 1, shadow, sp);
  return sp. attenuation;
}

[shader("closesthit")] void ClosestHitMain(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attr) {
  uint instance_id = InstanceID(), primitive_id = PrimitiveIndex();
  if (! payload. bounce) {
    payload. hit = true;
    payload. instance_id = instance_id;
  }
  float3 hitpos = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();
  // Calculate normal
  uint id = offset[instance_id] + primitive_id;
  uint3 vid = triangles[id];
  float3 p0 = vertices[vid.x];
  float3 p1 = vertices[vid.y];
  float3 p2 = vertices[vid.z];
  float3 N = normalize(cross(p1 - p0, p2 - p0));
  // N = normalize(mul((float3x3) ObjectToWorld3x4(), N));
  if (dot(WorldRayDirection(), N) > 0.0)
    N = - N;
  float3 planeN = N;
  // float3 B = normalize(p1 - p0);
  // if (abs(dot(N, B)) > 1e-6)
  //   B = normalize(B - dot(N, B) * N);
  // float3 T = cross(N, B);
  
  // Load material (this will also update N with normal map if available)
  Material mat = getMaterial(instance_id, primitive_id, attr, N, p0, p1, p2);
  mat. roughness = clamp(mat. roughness, 1e-2, 1.0);
  float3 T, B;
  getOrthonormalBasis(N, T, B);
  if (Rand(payload. seed) < p) {
    payload. bounce = 0;
    return ;
  } payload. coef /= 1 - p;
  if (Rand(payload. seed) < 1 - mat. alpha) {
    payload. nxt_origin = hitpos + WorldRayDirection() * 1e-4;
    payload. bounce = 1;
    return ;
  }
  if (payload. count_emission) payload. color += payload. coef * mat. emission;
  float3x3 M = transpose(float3x3 (T, B, N));
  // Sample a direction
  // float phi = Rand(payload. seed) * 2 * PI, cosTheta = Rand(payload. seed), sinTheta = sqrt(1 - sqr(cosTheta));
  // float3 inDir = sinTheta * (cos(phi) * T + sin(phi) * B) + cosTheta * N;
  // float3 outDir = - WorldRayDirection();
  // float P = 1 / (2 * PI);
  float3 outDir = - WorldRayDirection(), inDir;
  float3 F = FresnelSchlick(calcF0(mat), dot(N, outDir));
  float p_mix = clamp(luminance(F) + (1 - mat. roughness) * 0.1, 0.05, 0.95);
  float p_trans = clamp(luminance(mat. transmission), 0.05, 0.95); // 防止除以 0
  rayComponent component; // 0: specular, 1 : diffuse, 2 : transmission
  float alpha = sqr(mat. roughness), alpha2 = sqr(alpha);
  if (Rand(payload. seed) <= p_mix) {
    component = SPECULAR;
    do {
      float phi = Rand(payload. seed) * 2 * PI, xi = Rand(payload. seed), cosTheta = sqrt(xi / ((1 - xi) * alpha2 + xi)), sinTheta = cosTheta >= 1.0 ? 0 : sqrt(1 - sqr(cosTheta));
      float3 h = mul(M, float3 (sinTheta * cos(phi), sinTheta * sin(phi), cosTheta));
      inDir = h * dot(outDir, h) * 2 - outDir;
    } while (dot(N, inDir) < 0);
  } else if (Rand(payload. seed) <= p_trans)
    component = TRANSMISSIVE;
  else {
    component = DIFFUSE;
    float r = sqrt(Rand(payload. seed)), phi = Rand(payload. seed) * 2 * PI;
    inDir = mul(M, float3 (r * cos(phi), r * sin(phi), sqrt(1 - sqr(r))));
  }
  float P;
  if (component != TRANSMISSIVE) {
    float3 h = normalize(inDir + outDir);
    float n_h = dot(N, h);
    float pd = dot(N, inDir) / PI, ps = calcD(alpha, n_h) * n_h / (4 * dot(outDir, h));
    P = component ? (1 - p_mix) * (1 - p_trans) * pd : p_mix * ps;
  } else P = (1 - p_mix) * p_trans;

  float3 light_contribution = float3 (0.0, 0.0, 0.0);
  for (uint i=0; i<misc.num_point_lights; i++) {
    float3 lightDir = point_lights[i]. position - hitpos;
    float dis = length(lightDir);
    if (dis < 1e-4) continue;
    lightDir /= dis;
    if (dot(N, lightDir) <= 0.0f) continue;
    float3 at = CalcLightAttenuation(hitpos + 1e-4 * lightDir, lightDir, dis - 1e-4);
    float3 fs, fd;
    BRDF(mat, lightDir, outDir, N, fs, fd);
    // payload. color = at;
    // payload. bounce = 0;
    // return ;
    light_contribution += at * (fs + (1 - mat. transmission) * fd) * dot(N, lightDir) * point_lights[i]. color / sqr(dis);
  }
  for (uint i=0; i<misc.num_emissive_tris; i++) {
    uint tri_id = emissive_tris[i]. x, mat_id = emissive_tris[i]. y;
    if (tri_id == id) continue;
    uint3 vid = triangles[tri_id];
    float3 p0 = vertices[vid.x];
    float3 p1 = vertices[vid.y];
    float3 p2 = vertices[vid.z];
    float3 Ni = cross(p1 - p0, p2 - p0);
    float area = length(Ni); Ni /= area, area /= 2;
    float s = sqrt(Rand(payload. seed)), t = Rand(payload. seed);
    float3 pos = (1 - s) * p0 + s * t * p1 + s * (1 - t) * p2;
    float3 lightDir = pos - hitpos;
    float dis = length(lightDir);
    if (dis < 1e-4) continue;
    lightDir /= dis;
    float N_D = dot(N, lightDir), Ni_D = abs(dot(Ni, lightDir));
    if (N_D <= 0.0f) continue;
    float3 at = CalcLightAttenuation(hitpos + 1e-4 * lightDir, lightDir, dis - 2e-4);
    float3 fs, fd;
    BRDF(mat, lightDir, outDir, N, fs, fd);
    light_contribution += at * (fs + (1 - mat. transmission) * fd) * materials[mat_id]. emission * N_D * Ni_D / sqr(dis) * area;
  }
  payload. color += payload. coef * light_contribution;
  if (component != TRANSMISSIVE) {
    payload. count_emission = 0;
    if (dot(planeN, inDir) > 0) {
      float3 fs, fd;
      BRDF(mat, inDir, outDir, N, fs, fd);
      payload. coef *= (component == SPECULAR ? fs : fd * (1 - mat. transmission)) * dot(N, inDir) / P;
      payload. bounce = 1;
      payload. nxt_origin = hitpos + 1e-4 * inDir;
      payload. nxt_direction = inDir;
    } else {
      payload. bounce = 0;
    }
  } else {
    payload. coef *= (1 - mat. metallic) * mat. transmission * (1 - F) / P;
    payload. bounce = 1;
    payload. nxt_origin = hitpos + 1e-4 * WorldRayDirection();
  }
}