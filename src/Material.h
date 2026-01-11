#pragma once
#include "long_march.h"
#include <string>
#include <cstring>

// GPU-side material data (POD type, can be uploaded to GPU)
// This must match the HLSL Material structure exactly
struct MaterialGPUData {
    glm::vec3 base_color;      // 基础色/色调 (final_color = base_color * texture_color)
    float roughness;            // Surface roughness [0,1]
    
    float metallic;             // Metallic factor [0,1]
    int texture_index;
    int normal_index;
    glm::vec3 emission;           // Padding for GPU alignment (total size = 32 bytes)
    glm::vec3 transmission;
    float alpha;
    float ior;
    float clearcoat;
    float clearcoat_roughness;
    glm::vec3 volume_emission;
    float volume_density;
    glm::vec3 volume_scatter;
};

// Material structure for ray tracing with texture support
// 
// base_color 的作用:
// - 无纹理时: 作为物体的颜色
// - 有纹理时: 作为色调(tint)与纹理颜色相乘
//   例如: base_color = (1.0, 0.5, 0.5) 会给纹理添加红色调
//         base_color = (1.0, 1.0, 1.0) 保持纹理原色
//         base_color = (0.5, 0.5, 0.5) 使纹理变暗50%
struct Material {
    glm::vec3 base_color;      // 基础色/色调
    float roughness;            // Surface roughness [0,1]
    
    float metallic;             // Metallic factor [0,1]
    int texture_index;
    int normal_index;
    glm::vec3 emission;           
    glm::vec3 transmission;
    float alpha;
    float ior;
    float clearcoat;
    float clearcoat_roughness;

    glm::vec3 volume_emission;
    float volume_density;
    glm::vec3 volume_scatter;    
    
    // Texture path (CPU only, not uploaded to GPU)
    std::string texture_path;
    //Normal path (CPU only)
    std::string normal_path; 
    
    // Default constructor - pure color material
    Material()
        : base_color(0.8f, 0.8f, 0.8f)
        , roughness(0.5f)
        , metallic(0.0f)
        , texture_index(-1)
        , normal_index(-1)
        , emission(0.0f, 0.0f, 0.0f) 
        , transmission(0.0f, 0.0f, 0.0f)
        , alpha(1.0f)
        , ior(1.0f)
        , clearcoat(0.0f)
        , clearcoat_roughness(0.0f)
        , volume_emission(0.0f, 0.0f, 0.0f)
        , volume_density(0.0f)
        , volume_scatter(0.0f, 0.0f, 0.0f)
        , texture_path("") 
        , normal_path("") {}

    // Constructor with color (for manual material specification)
    Material(const glm::vec3& color, float rough = 0.5f, float metal = 0.0f, const glm::vec3& glow = glm::vec3(0.0f, 0.0f, 0.0f), const glm::vec3& trans = glm::vec3(0.0f, 0.0f, 0.0f), float a = 1.0f, float eta = 1.0f, float ccintensity = 0.0f, float ccrough = 0.0f, const glm::vec3& v_emission = glm::vec3(0.0f, 0.0f, 0.0f), float v_density = 0.0f, const glm::vec3& v_scatter = glm::vec3(0.0f, 0.0f, 0.0f) )
        : base_color(color)
        , roughness(rough)
        , metallic(metal)
        , texture_index(-1)
        , normal_index(-1)
        , emission(glow)
        , transmission(trans)
        , alpha(a)
        , ior(eta)
        , clearcoat(ccintensity)
        , clearcoat_roughness(ccrough)
        , volume_emission(v_emission)
        , volume_density(v_density)
        , volume_scatter(v_scatter)
        , texture_path("") 
        , normal_path("") {}
    
    // Helper methods
    bool HasTexture() const { return !texture_path.empty(); }
    bool HasNormal() const { return !normal_path.empty(); }
    bool IsVolumeMedium() const {return volume_density > 0.0f;}
    const std::string& GetTexturePath() const { return texture_path; }
    const std::string& GetNormalPath() const { return normal_path; }
    void SetTexturePath(const std::string& path) { texture_path = path; }
    void SetNormalPath(const std::string& path){ normal_path = path;}
    void ClearTexture() { 
        texture_path.clear(); 
        texture_index = -1; 
        normal_index = -1;
        normal_path.clear();
    }
    
    // Convert to GPU data (only POD fields, no std::string)
    MaterialGPUData ToGPUData() const {
        MaterialGPUData gpu_data;
        gpu_data.base_color = base_color;
        gpu_data.roughness = roughness;
        gpu_data.metallic = metallic;
        gpu_data.texture_index = texture_index;
        gpu_data.normal_index = normal_index;
        gpu_data.emission = emission; 
        gpu_data.transmission = transmission; 
        gpu_data.alpha = alpha; 
        gpu_data.ior = ior;
        gpu_data.clearcoat = clearcoat;
        gpu_data.clearcoat_roughness = clearcoat_roughness;
        gpu_data.volume_emission = volume_emission;
        gpu_data.volume_density = volume_density;
        gpu_data.volume_scatter = volume_scatter;
        if(gpu_data.volume_density>0.0f)grassland::LogInfo("Volumetric medium found!");
        return gpu_data;
    }
};


