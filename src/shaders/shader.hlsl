
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
  float ior;
  float clearcoat;
  float clearcoat_roughness;
  float sheen;
  float sheen_tint;
  float subsurface;
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
  int vertex_count;       // Number of vertices for this instance
  int triangle_count;     // Number of triangles (0 if no material IDs)
  int index_offset;       // Offset in global index buffer
  int normal_offset;      // Offset in global normal buffer (-1 if no normals)
  int has_normals;        // Boolean flag (0 or 1)
  int padding[3];         // Align to 48 bytes
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
StructuredBuffer<uint> global_indices : register(t2, space10);         // Global index buffer
StructuredBuffer<float3> global_normals : register(t3, space10);       // Global vertex normals (no padding)
StructuredBuffer<InstanceMetadata> instance_metadata : register(t0, space11);  // Per-instance metadata
Texture2D<float4> textures[256] : register(t0, space12);                          // Texture array (bindless)
SamplerState g_Sampler : register(s0, space13);
StructuredBuffer <PointLight> point_lights : register (t0, space14);
Texture2D<float4> normalmaps[256] : register(t0, space15); 
SamplerState normalmap_sampler : register(s0, space16);
Texture2D<float4>hdr_skybox: register(t0, space17);
SamplerState skybox_sampler : register(s0, space18);
StructuredBuffer<uint3> emissive_tris : register(t0, space19);

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
  int current_medium_id;// 当前所在介质的材质 ID，-1 表示不在任何介质中
  int scattered_count;
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
  payload. current_medium_id = - 1;
  payload.scattered_count = 0;


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

static float G = 0.5;

// Henyey-Greenstein phase function for volume scattering
// g: asymmetry parameter [-1, 1]
//    g > 0: forward scattering (前向散射)
//    g < 0: backward scattering (后向散射)
//    g = 0: isotropic scattering (各向同性)
// cosTheta: cosine of the angle between incident and scattered directions
// Returns: probability density p(cosθ) = (1-g²) / (4π(1+g²-2g·cosθ)^(3/2))
float HenyeyGreensteinPhaseFunction(float g, float cosTheta) {
  float denom = 1.0 + g * g - 2.0 * g * cosTheta;
  return (1.0 - g * g) / (4.0 * PI * pow(abs(denom), 1.5));
}

// Sample a direction using Henyey-Greenstein phase function
// g: asymmetry parameter, g > 0 for forward scattering
// incident_dir: incident direction (normalized)
// Returns: scattered direction (normalized)
// 使用 Henyey-Greenstein 相位函数采样散射方向
// 采样公式：cosθ = (1/(2g)) * [1 + g² - ((1-g²)/(1-g+2g·ξ))²]
float3 SampleHenyeyGreensteinDirection(float g, float3 incident_dir, inout uint seed) {
  float cos_theta;
  
  if (abs(g) < 1e-3) {
    // g ≈ 0, use isotropic sampling
    cos_theta = 2.0 * Rand(seed) - 1.0;
  } else {
    // Henyey-Greenstein sampling
    float xi = Rand(seed);
    float sqr_term = (1.0 - g * g) / (1.0 - g + 2.0 * g * xi);
    cos_theta = (1.0 / (2.0 * g)) * (1.0 + g * g - sqr_term * sqr_term);
    cos_theta = clamp(cos_theta, -1.0, 1.0);
  }
  
  float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
  float phi = 2.0 * PI * Rand(seed);
  
  // Build local coordinate system around incident direction
  float3 w = incident_dir;
  float3 u;
  if (abs(w.z) < 0.999) {
    u = normalize(cross(float3(0, 0, 1), w));
  } else {
    u = normalize(cross(float3(1, 0, 0), w));
  }
  float3 v = cross(w, u);
  
  // Transform sampled direction to world space
  return normalize(
    sin_theta * cos(phi) * u +
    sin_theta * sin(phi) * v +
    cos_theta * w
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
    out float3 transmittance,
    out float3 scattering_coefficient
) {
  // 默认值：无散射，完全透射
  scatter_distance = t_max;
  new_direction = float3(0, 0, 0);
  transmittance = float3(1, 1, 1);
  scattering_coefficient = float3(1, 1, 1);
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
    transmittance = exp(-sigma_t * t_max);
    scattering_coefficient = float3(1, 1, 1);  // 未发生散射，保持为1
    return false;
  }
  
  // 散射事件发生！
  scatter_distance = sampled_t;
  
  // Tyndall effect: strong forward scattering (g > 0.8 for pronounced god rays)
  // g = 0.85-0.95: very forward-scattering, creates dramatic light beams
  // g = 0.7-0.8: balanced forward scattering
  // g = 0.5: moderate forward scattering
  float g = G;
  float3 incident_dir = normalize(WorldRayDirection());
  new_direction = SampleHenyeyGreensteinDirection(g, incident_dir, seed);
  
  // 分别计算透射率和散射系数比
  // transmittance: exp(-σ_t * t) - 到达散射点的衰减
  // scattering_coefficient: (σ_s / σ_t) - 散射采样的PDF修正项
  // 在计算直接光照时只用 transmittance
  // 在更新路径throughput时才乘以 scattering_coefficient
  transmittance = exp(-sigma_t * sampled_t);
  scattering_coefficient = sigma_s / max(1e-10, sigma_t);
  
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
  while(distance < 0);
  // Beer-Lambert law: transmittance = exp(-extinction * distance)
  // Extinction coefficient = density (total attenuation from both scattering and absorption)
  // 使用 Beer-Lambert 定律计算透射率：transmittance = exp(-σ_t × distance)
  // 消光系数 σ_t = volume_density（包含散射和吸收的总衰减）
  float extinction = mat.volume_density;
  transmittance.x = exp(-extinction * distance);
  transmittance.y = exp(-extinction * distance);
  transmittance.z = exp(-extinction * distance);
  // Volumetric emission (attenuated by self-absorption)
  // 体积发光贡献（被自吸收衰减）
  // 沿路径积分：∫ emission × exp(-σ_t × t) dt = emission × (1 - exp(-σ_t × distance)) / σ_t
  // 正确公式需要除以密度
  emission = mat.volume_emission * (1.0 - exp(-optical_depth));
}

[shader("miss")] void MissMain(inout RayPayload payload) {
  if (! payload. bounce) {
    payload.hit = false;
    payload.instance_id = 0xFFFFFFFF;
  }
  
  // Handle volumetric medium when ray misses (goes to infinity)
  // 当光线未击中物体（射向天空）时，处理介质的体积效应
  float3 skybox_color = SampleSkybox(WorldRayDirection());
  
  if (payload.current_medium_id != -1) {
    // Ray is traveling through a medium - apply volumetric effects over infinite distance
    // 光线在介质中传播 - 在无限距离上应用体积效应
    // For practical purposes, use a large but finite distance (e.g., 1e4)
    float max_distance = 1e4;
    float3 volume_emission, volume_transmittance;
    SampleVolumeContribution(payload.current_medium_id, max_distance, volume_emission, volume_transmittance);
    
    // Add volume emission contribution
    payload.color += payload.coef * volume_emission;
    
    // Skybox color attenuated by medium transmittance
    payload.color += payload.coef * volume_transmittance * skybox_color;
  } else {
    // No medium - directly add skybox contribution
    payload.color += payload.coef * skybox_color;
  }
  
  payload. bounce = 0;
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

Material getMaterial(in uint instance_id, in uint primitive_id, in BuiltInTriangleIntersectionAttributes attr, inout float3 N, in float3 p0, in float3 p1, in float3 p2, out int medium_id) {
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
  if(mat.volume_density > 0.00001f)
    medium_id = material_id;
  else
    medium_id = -1;
  if(mat.texture_index != -1 && metadata.has_uv == 1) {
    float2 bc = attr.barycentrics;
    int uv_offset = metadata.uv_offset;
    int index_offset = metadata.index_offset;
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
    // mat. alpha = 1;

    // float3 tmp = float3(1.0, 1.0, 1.0)-mat.transmission;
    // tmp = tmp * texture_color.a;
    // mat.transmission = float3(1.0, 1.0, 1.0)-tmp;
    
    
    // Sample normal map
    if(mat.normal_index != -1) {
        float3 normalMapSample = normalmaps[mat.normal_index].SampleLevel(normalmap_sampler, uv, 0).xyz;
        
        // Convert from [0,1] to [-1,1] range
        float3 tangentNormal = normalMapSample * 2.0 - 1.0;

        float3 baseN = normalize(N); // Store interpolated normal before perturbation
        float2 duv1 = uvx1 - uvx0, duv2 = uvx2 - uvx0;
        float3 dp1  = p1 - p0,    dp2  = p2 - p0;
        float r = 1.0 / (duv1.x * duv2.y - duv1.y * duv2.x + 1e-8);
        float3 T = (dp1 * duv2.y - dp2 * duv1.y) * r;
        float3 B = (dp2 * duv1.x - dp1 * duv2.x) * r;

        // Re-orthogonalize tangent space against the interpolated normal so T/B/N are mutually orthogonal
        T = normalize(T - baseN * dot(baseN, T));
        B = normalize(B - baseN * dot(baseN, B));
        B = normalize(B - T * dot(T, B));
        // Fix handedness to avoid mirrored normal maps
        if (dot(cross(T, B), baseN) < 0.0) B = -B;

        float3x3 TBN = float3x3(T, B, baseN);

        // Transform normal from tangent space to world space
        N = normalize(mul(tangentNormal, TBN));
        
        // Ensure normal faces the correct direction
        if (dot(N, -WorldRayDirection()) < 0.0)
          N = -N;

    }
  }
  if (mat. alpha != 0 && mat. ior != 1) mat. alpha = 1;
  return mat;
}

float3 getEmission(in uint instance_id, in uint primitive_id, in float3 bc, in float3 p0, in float3 p1, in float3 p2) {
  BuiltInTriangleIntersectionAttributes attr;
  attr. barycentrics = float2 (bc. y, bc. z);
  float3 _ = float3 (1.0f, 0.0f, 0.0f); int __;
  Material res = getMaterial(instance_id, primitive_id, attr, _, p0, p1, p2, __);
  return res. emission * res. base_color;
}



static float p = 0.1;


float sqr(in float x) { return x * x; }
float luminance(in float3 c) {
  return 0.2126 * c. r + 0.7152 * c. g + 0.0722 * c. b;
}
float3 calcF0(in Material mat) {
  float F0 = sqr((mat. ior - 1) / (mat. ior + 1));
  return lerp(float3 (F0, F0, F0), mat. base_color, mat. metallic);
}
float3 FresnelSchlick(in float3 F0, in float3 n_v) {
  return F0 + (float3 (1.0f, 1.0f, 1.0f) - F0) * pow(clamp(1 - n_v, 0.0f, 1.0f), 5);
}
float3 calcF_base(in Material mat, in float n_v) {
  return FresnelSchlick(calcF0(mat), n_v);
}
float3 calcF_coat(in float n_v) {
  return FresnelSchlick(float3 (0.04f, 0.04f, 0.04f), n_v);
}
float calcD_base(in float alpha, in float n_h) {
  return sqr(alpha) / (PI * sqr(sqr(n_h) * sqr(alpha) + (1 - sqr(n_h))));
}
float calcD_coat(in float alpha, in float n_h) {
  return 1 - alpha < 1e-3 ? 1 / PI : (sqr(alpha) - 1) / (PI * 2 * log(alpha) * (sqr(n_h) * sqr(alpha) + (1 - sqr(n_h))));
}
float3 calcSheen(in Material mat, in float h_l) {
  float lu = luminance(mat. base_color);
  float3 Ctint = lu > 1e-8 ? mat. base_color / lu : float3 (1.0f, 1.0f, 1.0f);
  return lerp(float3 (1.0f, 1.0f, 1.0f), Ctint, mat. sheen_tint) * mat. sheen * pow(clamp(1 - h_l, 0.0f, 1.0f), 5);
}
float3 calcDiffuse(in Material mat, in float n_l, in float n_v, in float h_l) {
  float F_L = pow(clamp(1 - n_l, 0.0f, 1.0f), 5);
  float F_V = pow(clamp(1 - n_v, 0.0f, 1.0f), 5);
  float R_R = 2 * mat. roughness * sqr(h_l);
  float f_base = (1 + (R_R - 0.5f) * F_L) * (1 + (R_R - 0.5f) * F_V);
  float F_SS = (1 + (R_R * 0.5f - 1.0f) * F_L) * (1 + (R_R * 0.5f - 1.0f) * F_V);
  float f_sub = 1.25f * (F_SS * (1 / (n_l + n_v + 1e-7) - 0.5f) + 0.5f);
  return mat. base_color / PI * lerp(f_base, f_sub, mat. subsurface);
}
void BRDF(in Material mat, in float3 oi, in float3 oo, in float3 n, in float3 pn, out float3 fs, out float3 fd, out float3 fc) {
  float3 h = normalize(oi + oo);
  float n_oi = dot(n, oi), n_oo = dot(n, oo), n_h = dot(n, h);
  if (n_oi <= 0.0f || n_oo <= 0.0f) {
    fs = fd = float3 (0.0, 0.0, 0.0);
  } else {
    float3 F = calcF_base(mat, dot(oo, h));
    float alpha = sqr(mat. roughness);
    float D = calcD_base(alpha, n_h);
    float k = sqr(alpha + 1) / 8;
    float G = n_oi / lerp(n_oi, 1.0, k) * n_oo / lerp(n_oo, 1.0, k);
    fs = F * D * G / (4 * n_oi * n_oo + 1e-7);
    // fd = (1 - mat. metallic) / PI * mat. base_color * (1 - F) * (1 - mat. transmission);
    fd = (calcDiffuse(mat, n_oi, n_oo, dot(h, oi)) + calcSheen(mat, dot(h, oi))) * (1 - F) * (1 - mat. transmission);
  }
  if (mat. clearcoat != 0) {
    float3 h = normalize(oi + oo);
    float n_oi = dot(pn, oi), n_oo = dot(pn, oo), n_h = dot(pn, h);
    if (n_oi <= 0.0f || n_oo <= 0.0f) {
      fc = float3 (0.0, 0.0, 0.0);
    } else {
      float3 F = calcF_coat(dot(oo, h));
      float alpha = sqr(mat. clearcoat_roughness);
      float D = calcD_coat(alpha, n_h);
      float G = 2 * n_oi / (n_oi + sqrt(lerp(sqr(n_oi), 1.0, 0.0625))) * 2 * n_oo / (n_oo + sqrt(lerp(sqr(n_oo), 1.0, 0.0625)));
      fc = mat. clearcoat * F * D * G / (4 * n_oi * n_oo + 1e-7);
    }
    float att = (1 - mat. clearcoat * calcF_coat(clamp(n_oi, 0.0, 1.0)). r) * (1 - mat. clearcoat * calcF_coat(clamp(n_oo, 0.0, 1.0)). r);
    fs *= att, fd *= att;
  } else fc = 0;
}

#define assert(cond) if (!(cond)) { while (1); }

enum rayComponent {
  CLEARCOAT, SPECULAR, DIFFUSE, TRANSMISSIVE
} ;

struct ShadowPayload { 
  float3 attenuation; 
  float3 emission;
  float pre_t;
  float t_max;
  int current_medium_id;
};
[shader("anyhit")] void ShadowHit(inout ShadowPayload payload, BuiltInTriangleIntersectionAttributes attr) {
  uint instance_id = InstanceID(), primitive_id = PrimitiveIndex();
  float3 hitpos = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();
  uint id = offset[instance_id] + primitive_id;
  uint3 vid = triangles[id];
  float3 p0 = vertices[vid.x];
  float3 p1 = vertices[vid.y];
  float3 p2 = vertices[vid.z];
  float3 N = normalize(cross(p1 - p0, p2 - p0));
  if (dot(WorldRayDirection(), N) > 0.0) N = - N;
  float3 planeN = N;
  if(payload.current_medium_id != -1) {
    float3 volume_emission, volume_transmittance;
    SampleVolumeContribution(payload.current_medium_id, RayTCurrent() - payload.pre_t, volume_emission, volume_transmittance);
    payload. attenuation *= volume_transmittance;
  }
  int medium_id;
  Material mat = getMaterial(instance_id, primitive_id, attr, N, p0, p1, p2, medium_id);
  mat. roughness = clamp(mat. roughness, 1e-2, 1.0);
  float3 F = calcF_base(mat, dot(N, - WorldRayDirection()));
  float Fcc = calcF_coat(dot(planeN, - WorldRayDirection())). r;
  float3 surface_transmittance = (1 - mat. alpha) * float3 (1.0, 1.0, 1.0) + mat. alpha * (1 - mat. metallic) * mat. transmission * (1 - F) * sqr(1 - mat. clearcoat * Fcc);
  payload. attenuation *= surface_transmittance;
  if(payload.current_medium_id == medium_id) {
    payload.current_medium_id = -1;
  } else if(medium_id != -1){
    payload.current_medium_id = medium_id;
  }
  payload.pre_t = max(payload.pre_t,RayTCurrent());
  if (luminance(payload. attenuation) < 1e-3) AcceptHitAndEndSearch();
  else IgnoreHit();
}
[shader("miss")] void ShadowMiss(inout ShadowPayload payload) {
  
}
[shader("closesthit")] void ShadowClosestHit(inout ShadowPayload payload, in BuiltInTriangleIntersectionAttributes attr) {}

float3 CalcLightAttenuation(float3 origin, float3 dir, float dist_to_light, int medium_id) {
  ShadowPayload sp;
  sp. attenuation = float3 (1.0, 1.0, 1.0);
  sp. current_medium_id = medium_id;
  while(medium_id == -1);
  sp.pre_t = 0;
  sp.t_max = dist_to_light;
  RayDesc shadow;
  shadow.Origin = origin;
  shadow.Direction = dir;
  shadow.TMin = 1e-4;
  shadow.TMax = dist_to_light;
  TraceRay(as,
      RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
      0xFF, 1, 1, 1, shadow, sp);
  float3 volume_emission, volume_transmittance;
  SampleVolumeContribution(sp.current_medium_id, sp.t_max-sp.pre_t, volume_emission, volume_transmittance);

  sp. attenuation *= volume_transmittance;
  return sp. attenuation;
}

static uint scatter_lim = 5;

[shader("closesthit")] void ClosestHitMain(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attr) {
  uint instance_id = InstanceID(), primitive_id = PrimitiveIndex();
  InstanceMetadata metadata = instance_metadata[instance_id];
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
  float3 geometricN = normalize(cross(p1 - p0, p2 - p0));
  float3 N = geometricN;
  if (metadata.has_normals == 1 && metadata.normal_offset >= 0) {
    int base = metadata.index_offset + primitive_id * 3;
    int idx0 = global_indices[base + 0];
    int idx1 = global_indices[base + 1];
    int idx2 = global_indices[base + 2];
    float3 n0 = global_normals[metadata.normal_offset + idx0];
    float3 n1 = global_normals[metadata.normal_offset + idx1];
    float3 n2 = global_normals[metadata.normal_offset + idx2];
    float3 bc = float3(1.0 - attr.barycentrics.x - attr.barycentrics.y, attr.barycentrics.x, attr.barycentrics.y);
    N = normalize(n0 * bc.x + n1 * bc.y + n2 * bc.z);
  }
  bool flip = 0;
  // N = normalize(mul((float3x3) ObjectToWorld3x4(), N));
  if (dot(WorldRayDirection(), N) > 0.0)
    N = - N, flip = 1;
  float3 planeN = geometricN;
  if (flip)
    planeN = -planeN;
  // Load material (this will also update N with normal map if available)
  //Tackle volume scattering and emission before surface interaction
  if(payload.current_medium_id != -1) {
    float3 ve_color = materials[payload.current_medium_id].volume_emission;
    float scatter_distance;
    float3 new_direction, transmittance_to_scatter, scattering_pdf_ratio;
    bool scattered = SampleVolumeScattering(payload.current_medium_id, RayTCurrent(), payload.seed, scatter_distance, new_direction, transmittance_to_scatter, scattering_pdf_ratio);
    if (scattered && scatter_distance < RayTCurrent() && payload.scattered_count <= scatter_lim) {
      // Volume scattering event occurs before surface hit
      float3 scatter_point = WorldRayOrigin() + WorldRayDirection() * scatter_distance;
      // Account for volume contribution up to scattering point
      float3 volume_emission, volume_transmittance;
      SampleVolumeContribution(payload.current_medium_id, scatter_distance, volume_emission, volume_transmittance);
      payload. color += payload. coef * volume_emission;
      
      // Account for the contribution of light sources on scattered point
      // 计算散射点处点光源和面光源的贡献
      float3 light_contribution = float3(0.0, 0.0, 0.0);
      
      // Henyey-Greenstein 相位函数 (g = 0.7, 前向散射)
      // 对于前向散射，光主要沿原方向散射
      float g = G;
      float3 incident_dir = normalize(WorldRayDirection());
      if(payload.scattered_count <= scatter_lim){
        for (uint i = 0; i < misc.num_point_lights; i++) {
          float3 lightDir = point_lights[i].position - scatter_point;
          float dis = length(lightDir);
          if (dis < 1e-4) continue;
          lightDir /= dis;
          
          // 计算入射方向与散射到光源方向之间的夹角余弦
          float cosTheta = dot(incident_dir, lightDir);
          
          // 使用 Henyey-Greenstein 相位函数计算该方向的散射概率
          float phase_function = HenyeyGreensteinPhaseFunction(g, cosTheta);
          
          // 计算阴影光线的衰减
          float3 at = CalcLightAttenuation(scatter_point + 1e-4 * lightDir, lightDir, dis - 1e-4, payload.current_medium_id);
          
          // 体积散射方程：L_scatter = phase_function × L_light × attenuation / distance²
          // phase_function 现在是根据实际散射方向计算的 HG 相位函数值
          light_contribution += phase_function * at * point_lights[i].color / sqr(dis);
        }
        // Emissive triangles (area lights) contribution
        for (uint i = 0; i < misc.num_emissive_tris; i++) {
          uint tri_id = emissive_tris[i].x, mat_id = emissive_tris[i].y;
          uint3 vid = triangles[tri_id];
          float3 p0 = vertices[vid.x];
          float3 p1 = vertices[vid.y];
          float3 p2 = vertices[vid.z];
          float3 Ni = cross(p1 - p0, p2 - p0);
          float area = length(Ni);
          Ni /= area;
          area /= 2;
          
          // 在面光源上均匀采样一点
          float s = sqrt(Rand(payload.seed)), t = Rand(payload.seed);
          float3 pos = (1 - s) * p0 + s * t * p1 + s * (1 - t) * p2;
          float3 lightDir = pos - scatter_point;
          float dis = length(lightDir);
          if (dis < 1e-4) continue;
          lightDir /= dis;
          
          // 计算入射方向与散射到光源方向之间的夹角余弦
          float cosTheta = dot(incident_dir, lightDir);
          
          // 使用 Henyey-Greenstein 相位函数计算该方向的散射概率
          float phase_function = HenyeyGreensteinPhaseFunction(g, cosTheta);
          
          // 计算光源表面法线与光线方向的夹角余弦
          float Ni_D = abs(dot(Ni, -lightDir));
          if (Ni_D <= 0.0f) continue;
          // 计算阴影光线的衰减
          float3 E = getEmission(emissive_tris[i]. z, tri_id - offset[emissive_tris[i]. z], float3 (1 - s, s * t, s * (1 - t)), p0, p1, p2);
          float3 at = CalcLightAttenuation(scatter_point + 1e-4 * lightDir, lightDir, dis - 2e-4, payload.current_medium_id);
          // 面光源的辐射度方程：L_scatter = phase_function × emission × Ni_D × area × attenuation / distance²
          // phase_function 现在是根据实际散射方向计算的 HG 相位函数值
          light_contribution += phase_function * at * E * Ni_D * area / sqr(dis);
        }
        
        // 将光源的直接贡献加入颜色
        // 直接光照 = 到达散射点的throughput × phase_function × light
        // light_contribution 已包含 phase_function，所以只乘 transmittance
        payload.color += payload.coef * transmittance_to_scatter * light_contribution;
      }
      // Point lights contribution
      
      
      // 更新 throughput 用于后续的路径追踪
      // 完整的throughput更新 = transmittance × (σ_s / σ_t)
      payload.coef *= transmittance_to_scatter * scattering_pdf_ratio;
      payload.scattered_count ++;
      payload. nxt_origin = scatter_point + new_direction * 1e-4;
      payload. nxt_direction = new_direction;
      payload. bounce = 1;
      payload.count_emission = 0;
      return ;
    } else {
      // No scattering before surface hit, account for volume contribution up to surface
      float3 volume_emission, volume_transmittance;
      SampleVolumeContribution(payload.current_medium_id, RayTCurrent(), volume_emission, volume_transmittance);
      payload. color += payload. coef * volume_emission;
      payload. coef *= volume_transmittance;
    }
  }
  int medium_id;
  Material mat = getMaterial(instance_id, primitive_id, attr, N, p0, p1, p2, medium_id);
  mat. roughness = clamp(mat. roughness, 1e-2, 1.0);
  mat. clearcoat_roughness = clamp(mat. clearcoat_roughness, 1e-2, 1.0);
  if (! flip) mat. ior = 1 / mat. ior;
  float3 T, B;
  getOrthonormalBasis(N, T, B);
  float3 planeT, planeB;
  getOrthonormalBasis(planeN, planeT, planeB);
  if(payload. current_medium_id == medium_id) {
    payload.current_medium_id = -1;
  } else if(medium_id != -1){
    payload.current_medium_id = medium_id;
  }
  if (Rand(payload. seed) < p) {
    payload. bounce = 0;
    return ;
  } payload. coef /= 1 - p;
  if (Rand(payload. seed) < 1 - mat. alpha) {
    payload. nxt_origin = hitpos + WorldRayDirection() * 1e-4;
    payload. bounce = 1;
    return ;
  }
  float3x3 M = transpose(float3x3 (T, B, N)), planeM = transpose(float3x3 (planeT, planeB, planeN));
  // Sample a direction
  float3 outDir = - WorldRayDirection(), inDir;
  float3 F = calcF_base(mat, dot(N, outDir));
  float Fcc = calcF_coat(dot(planeN, outDir)). r;
  if (payload. count_emission) payload. color += payload. coef * (1 - mat. clearcoat * Fcc) * mat. emission * mat. base_color;
  float p_coat = clamp(mat. clearcoat * Fcc * 0.5, 0.01, 0.95);
  float p_mix = clamp(luminance(F) + (1 - mat. roughness) * 0.1, 0.05, 0.95);
  float p_trans = clamp(luminance(mat. transmission), 0.01, 0.95); // 防止除以 0
  float alpha = sqr(mat. roughness), alpha2 = sqr(alpha);
  float coat_alpha = sqr(mat. clearcoat_roughness), coat_alpha2 = sqr(coat_alpha);
  rayComponent component;
  if (Rand(payload. seed) <= p_coat) {
    component = CLEARCOAT;
    do {
      float xi = Rand(payload. seed);
      float cosTheta = 1 - coat_alpha2 < 1e-3 ? sqrt(xi) : sqrt((1 - pow(coat_alpha2, xi)) / (1 - coat_alpha2));
      cosTheta = clamp(cosTheta, 0, 1);
      float sinTheta = sqrt(1 - sqr(cosTheta)), phi = Rand(payload. seed) * 2 * PI;
      float3 h = mul(planeM, float3 (sinTheta * cos(phi), sinTheta * sin(phi), cosTheta));
      inDir = h * dot(outDir, h) * 2 - outDir;
    } while (dot(planeN, inDir) < 0);
  } else if (Rand(payload. seed) <= p_mix) {
    component = SPECULAR;
    do {
      float phi = Rand(payload. seed) * 2 * PI, xi = Rand(payload. seed), cosTheta = sqrt(xi / ((1 - xi) * alpha2 + xi));
      cosTheta = clamp(cosTheta, 0, 1);
      float sinTheta = sqrt(1 - sqr(cosTheta));
      float3 h = mul(M, float3 (sinTheta * cos(phi), sinTheta * sin(phi), cosTheta));
      inDir = h * dot(outDir, h) * 2 - outDir;
    } while (dot(N, inDir) < 0);
  } else if (Rand(payload. seed) <= p_trans) {
    component = TRANSMISSIVE;
    inDir = refract(- outDir, N, mat. ior);
  } else {
    component = DIFFUSE;
    float r = sqrt(Rand(payload. seed)), phi = Rand(payload. seed) * 2 * PI;
    inDir = mul(M, float3 (r * cos(phi), r * sin(phi), sqrt(1 - sqr(r))));
  }
  float P;
  if (component == DIFFUSE || component == SPECULAR) {
    float3 h = normalize(inDir + outDir);
    float n_h = dot(N, h);
    float pd = dot(N, inDir) / PI, ps = calcD_base(alpha, n_h) * n_h / (4 * dot(outDir, h));
    P = (component == DIFFUSE ? (1 - p_mix) * (1 - p_trans) * pd : p_mix * ps) * (1 - p_coat);
  } else if (component == TRANSMISSIVE) {
    P = (1 - p_coat) * (1 - p_mix) * p_trans;
  } else {
    float3 h = normalize(inDir + outDir);
    float n_h = dot(planeN, h);
    P = p_coat * calcD_coat(coat_alpha, n_h) * n_h / (4 * dot(outDir, h));
  }

  float3 light_contribution = float3 (0.0, 0.0, 0.0);
  bool NEE_for_specular = mat. roughness >= 0.1;
  bool NEE_for_coat = mat. clearcoat_roughness >= 0.1;
  for (uint i=0; i<misc.num_point_lights; i++) {
    float3 lightDir = point_lights[i]. position - hitpos;
    float dis = length(lightDir);
    if (dis < 1e-4) continue;
    lightDir /= dis;
    float3 att = CalcLightAttenuation(hitpos + 1e-4 * lightDir, lightDir, dis - 1e-4, payload.current_medium_id);
    float3 fs, fd, fc;
    BRDF(mat, lightDir, outDir, N, planeN, fs, fd, fc);
    if (dot(N, lightDir) > 0.0f) {
      if (! NEE_for_specular) fs = 0;
      light_contribution += att * (fs + fd) * dot(N, lightDir) * point_lights[i]. color / sqr(dis);
    }
    if (NEE_for_coat && dot(planeN, lightDir) > 0.0f && fc. r > 0) {
      light_contribution += att * fc * dot(planeN, lightDir) * point_lights[i]. color / sqr(dis);
    }
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
    float3 att = CalcLightAttenuation(hitpos + 1e-4 * lightDir, lightDir, dis - 2e-4,payload.current_medium_id);
    float3 fs, fd, fc;
    BRDF(mat, lightDir, outDir, N, planeN, fs, fd, fc);
    float N_D = dot(N, lightDir), pN_D = dot(planeN, lightDir), Ni_D = abs(dot(Ni, lightDir));
    att *= 1 - materials[mat_id]. clearcoat * calcF_coat(Ni_D);
    float3 E = getEmission(emissive_tris[i]. z, tri_id - offset[emissive_tris[i]. z], float3 (1 - s, s * t, s * (1 - t)), p0, p1, p2);
    if (N_D > 0.0f) {
      if (! NEE_for_specular) fs = 0;
      light_contribution += att * (fs + fd) * E * N_D * Ni_D / sqr(dis) * area;
    }
    if (NEE_for_coat && pN_D > 0.0f && fc. r > 0) {
      light_contribution += att * fc * E * pN_D * Ni_D / sqr(dis) * area;
    }
  }
  payload. color += payload. coef * light_contribution;
  if (component != TRANSMISSIVE) {
    // 如果是 specular 且是光滑的，就当作 delta 分布，正着过去采样光源。
    payload. count_emission = component == SPECULAR && ! NEE_for_specular || component == CLEARCOAT && ! NEE_for_coat;
    if (dot(planeN, inDir) > 0) {
      float3 fs, fd, fc;
      BRDF(mat, inDir, outDir, N, planeN, fs, fd, fc);
      payload. coef *= (component == CLEARCOAT ? fc : component == SPECULAR ? fs : fd) * dot(component == CLEARCOAT ? planeN : N, inDir) / P;
      payload. bounce = 1;
      payload. nxt_origin = hitpos + 1e-4 * inDir;
      payload. nxt_direction = inDir;
    } else {
      payload. bounce = 0;
    }
  } else {
    if (length(inDir) < 1e-3) {
      payload. bounce = 0;
    } else {
      inDir = normalize(inDir);
      float3 F = FresnelSchlick(calcF0(mat), - dot(N, inDir));
      payload. coef *= (1 - mat. clearcoat * Fcc) * (1 - mat. clearcoat * calcF_coat(dot(planeN, - inDir)). r) * (1 - mat. metallic) * mat. transmission * (1 - F) * sqr(mat. ior) / P;
      payload. bounce = 1;
      payload. nxt_origin = hitpos + 1e-4 * inDir;
      payload. nxt_direction = inDir;
    }
  }
  
}