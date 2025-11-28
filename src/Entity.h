#pragma once
#include "long_march.h"
#include "Material.h"
#include <vector>
#include <unordered_map>

// Entity represents a mesh instance with materials and transform
// Supports multiple materials from MTL files
class Entity {
public:
    Entity(const std::string& obj_file_path, 
           const Material& default_material = Material(),
           const glm::mat4& transform = glm::mat4(1.0f));

    ~Entity();

    // Load mesh from OBJ file (and MTL if referenced)
    bool LoadMesh(const std::string& obj_file_path);

    // Getters
    grassland::graphics::Buffer* GetVertexBuffer() const { return vertex_buffer_.get(); }
    grassland::graphics::Buffer* GetIndexBuffer() const { return index_buffer_.get(); }
    grassland::graphics::Buffer* GetUVBuffer() const { return uv_buffer_.get(); }
    grassland::graphics::Buffer* GetMaterialIDBuffer() const { return material_id_buffer_.get(); }
    
    // Get material by name (from MTL)
    const Material* GetMaterial(const std::string& name) const;
    
    // Get material by index (for material_id lookup)
    const Material* GetMaterial(int index) const;
    
    // Get default material (for entities without MTL or single material)
    const Material& GetDefaultMaterial() const { return default_material_; }
    
    // Get all materials (by index)
    const std::vector<Material>& GetMaterials() const { return materials_; }
    
    // Get material name mapping
    const std::unordered_map<std::string, int>& GetMaterialNameMap() const { return material_name_to_index_; }
    
    // Get mutable materials (for texture index assignment)
    std::vector<Material>& GetMutableMaterials() { return materials_; }
    
    // Get mutable default material
    Material& GetMutableDefaultMaterial() { return default_material_; }
    
    const glm::mat4& GetTransform() const { return transform_; }
    grassland::graphics::AccelerationStructure* GetBLAS() const { return blas_.get(); }

    // Setters
    void SetDefaultMaterial(const Material& material) { default_material_ = material; }
    void SetTransform(const glm::mat4& transform) { transform_ = transform; }

    // Create BLAS for this entity's mesh
    void BuildBLAS(grassland::graphics::Core* core);

    // Check if mesh is loaded
    bool IsValid() const { return mesh_loaded_; }
    
    // Check if mesh has UV coordinates
    bool HasUVCoordinates() const { return has_uv_coords_; }
    
    // Check if has MTL materials
    bool HasMTLMaterials() const { return !materials_.empty(); }
    
    // Check if has per-triangle material IDs
    bool HasMaterialIDs() const { return has_material_ids_; }
    
    // Get mesh statistics
    size_t GetNumVertices() const { return mesh_.NumVertices(); }
    size_t GetNumIndices() const { return mesh_.NumIndices(); }
    size_t GetNumTriangles() const { return mesh_.NumIndices() / 3; }
    
    // Get/Set material index offset (for multi-entity scenes)
    int GetMaterialOffset() const { return material_offset_; }
    void SetMaterialOffset(int offset) { material_offset_ = offset; }

    // Get raw UV and material ID data (returns nullptr if not available)
    const auto* GetUVCoordinates() const { return mesh_.TexCoords(); }
    const int* GetMaterialIDs() const { return mesh_.MaterialIds(); }
    const uint32_t* GetIndices() const { return mesh_.Indices(); }  // Get index data

private:
    grassland::Mesh<float> mesh_;
    Material default_material_;  // Default material (used if no MTL)
    std::vector<Material> materials_;  // Materials from MTL file (indexed by material_id)
    std::unordered_map<std::string, int> material_name_to_index_;  // Material name to index mapping
    glm::mat4 transform_;

    std::unique_ptr<grassland::graphics::Buffer> vertex_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> index_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> uv_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> material_id_buffer_;
    std::unique_ptr<grassland::graphics::AccelerationStructure> blas_;

    bool mesh_loaded_;
    bool has_uv_coords_;
    bool has_material_ids_;
    
    int material_offset_;  // Offset for global material indexing
};

