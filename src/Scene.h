#pragma once
#include "long_march.h"
#include "Entity.h"
#include "Material.h"
#include <vector>
#include <memory>
#include <string>
#include <unordered_map>

// Per-instance metadata for shader access (GPU-aligned)
struct InstanceMetadata {
    int uv_offset;              // Offset in global UV buffer (-1 if no UV)
    int material_id_offset;     // Offset in global material ID buffer (or direct material index if no IDs)
    int has_uv;                 // Boolean flag (0 or 1)
    int has_material_ids;       // Boolean flag (0 or 1)
    int vertex_count;           // Number of vertices (0 if no UV)
    int triangle_count;         // Number of triangles (0 if no material IDs)
    int index_offset;           // Offset in global index buffer
    int padding[1];             // Align to 32 bytes for GPU (reduced from 2 to 1)
};

struct PointLight {
    glm :: vec3 position;
    glm :: vec3 color;
    PointLight () : position (0.0f, 0.0f, 0.0f), color (0.0f, 0.0f, 0.0f) {}
    PointLight (const glm :: vec3 & pos, const glm :: vec3 & col) : position (pos), color (col) {}
} ;

// Scene manages a collection of entities and builds the TLAS
class Scene {
public:
    Scene(grassland::graphics::Core* core);
    ~Scene();

    // Add an entity to the scene
    void AddEntity(std::shared_ptr<Entity> entity);

    // Add a point light
    void AddPointLight(const PointLight &);

    // Remove all entities
    void Clear();

    // Build/rebuild the TLAS from all entities
    void BuildAccelerationStructures();

    // Update TLAS instances (e.g., for animation)
    void UpdateInstances();

    // Get the TLAS for rendering
    grassland::graphics::AccelerationStructure* GetTLAS() const { return tlas_.get(); }

    // Get materials buffer for all entities
    grassland::graphics::Buffer* GetMaterialsBuffer() const { return materials_buffer_.get(); }

    // Get global UV buffer
    grassland::graphics::Buffer* GetGlobalUVBuffer() const { return global_uv_buffer_.get(); }
    
    // Get global material ID buffer
    grassland::graphics::Buffer* GetGlobalMaterialIDBuffer() const { return global_material_id_buffer_.get(); }
    
    // Get instance metadata buffer
    grassland::graphics::Buffer* GetInstanceMetadataBuffer() const { return instance_metadata_buffer_.get(); }

    // Get global index buffer
    grassland::graphics::Buffer* GetGlobalIndexBuffer() const { return global_index_buffer_.get(); }

    // Get all entities
    const std::vector<std::shared_ptr<Entity>>& GetEntities() const { return entities_; }

    // Get number of entities
    size_t GetEntityCount() const { return entities_.size(); }

    // Texture management
    int LoadTexture(const std::string& filepath);  // Returns texture index
    grassland::graphics::Image* GetTexture(int index) const;
    grassland::graphics::Image* GetNormal(int index) const;
    size_t GetTextureCount() const { return textures_.size(); }
    size_t GetNormalCount() const { return normals_.size(); }

    // Get all point lights
    const std :: vector<PointLight> & GetPointLights() const { return point_lights_; }


private:
    void UpdateMaterialsBuffer();
    void AssignTextureIndices();  // Assign texture indices to materials
    void AssignMaterialOffsets();  // Assign global material offset to each entity
    void ConstructUVBuffer();
    void ConstructMaterialIDBuffer();
    void ConstructIndexBuffer();  // Build global index buffer
    void ConstructInstanceMetadataBuffer();  // Build instance metadata buffer

    grassland::graphics::Core* core_;
    std::vector<std::shared_ptr<Entity>> entities_;
    std::unique_ptr<grassland::graphics::AccelerationStructure> tlas_;
    std::unique_ptr<grassland::graphics::Buffer> materials_buffer_;
    std::vector <PointLight> point_lights_;
    
    // Global buffers for all entities combined (only actual data, no padding)
    std::unique_ptr<grassland::graphics::Buffer> global_uv_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> global_material_id_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> global_index_buffer_;  // Global index buffer
    std::unique_ptr<grassland::graphics::Buffer> instance_metadata_buffer_;  // Per-instance metadata
    
    // CPU-side instance metadata
    std::vector<InstanceMetadata> instance_metadata_;
    
    // Texture management
    std::vector<std::unique_ptr<grassland::graphics::Image>> textures_;
    std::unordered_map<std::string, int> texture_path_to_index_;
    //Normal management
    std::vector<std::unique_ptr<grassland::graphics::Image>> normals_;
};

