#include "Entity.h"
#include <fstream>
#include <sstream>
#include <filesystem>

Entity::Entity(const std::string& obj_file_path, 
               const Material& default_material,
               const glm::mat4& transform)
    : default_material_(default_material)
    , transform_(transform)
    , mesh_loaded_(false)
    , has_uv_coords_(false)
    , has_material_ids_(false)
    , material_offset_(0) {
    
    LoadMesh(obj_file_path);
}

Entity::~Entity() {
    blas_.reset();
    material_id_buffer_.reset();
    uv_buffer_.reset();
    index_buffer_.reset();
    vertex_buffer_.reset();
}

bool Entity::LoadMesh(const std::string& obj_file_path) {
    // Try to load the OBJ file
    std::string full_path = grassland::FindAssetFile(obj_file_path);
    
    if (mesh_.LoadObjFile(full_path) != 0) {
        grassland::LogError("Failed to load mesh from: {}", obj_file_path);
        mesh_loaded_ = false;
        has_uv_coords_ = false;
        has_material_ids_ = false;
        return false;
    }

    // Check if the mesh has UV coordinates
    has_uv_coords_ = (mesh_.TexCoords() != nullptr);
    
    // Check if the mesh has material IDs
    const int* mtlid = mesh_.MaterialIds();
    if(mtlid != nullptr && mtlid[0] != -1){
        has_material_ids_=1;
        grassland::LogInfo("legal material IDs found with first value {}", mtlid[0]);
    }
    else grassland::LogInfo("Material ID not found");
    
    // Load materials from mesh data (populated by tinyobjloader)
    const auto& material_data = mesh_.GetMaterialData();
    if (!material_data.empty()) {
        // Extract base directory for texture paths
        std::filesystem::path obj_path(full_path);
        std::string base_dir = obj_path.parent_path().string();
        
        materials_.clear();
        material_name_to_index_.clear();
        
        for (size_t i = 0; i < material_data.size(); ++i) {
            const auto& mat_data = material_data[i];
            
            Material mat;
            mat.base_color = glm::vec3(mat_data.diffuse[0], mat_data.diffuse[1], mat_data.diffuse[2]);
            
            // Convert Phong specular/shininess to PBR roughness/metallic (approximation)
            // High shininess -> low roughness
            mat.roughness = 1.0f - glm::clamp(mat_data.shininess / 1000.0f, 0.0f, 1.0f);
            
            // Use specular intensity to estimate metallic
            float spec_avg = (mat_data.specular[0] + mat_data.specular[1] + mat_data.specular[2]) / 3.0f;
            mat.metallic = glm::clamp(spec_avg, 0.0f, 1.0f);

            // Load emission (Ke) if provided by MTL/tinyobjloader
            mat.emission = glm::vec3(0.0f);
            // math_mesh.MaterialData now includes emission; copy it
            mat.emission = glm::vec3(mat_data.emission[0], mat_data.emission[1], mat_data.emission[2]);

            
            
            // Set texture path (absolute path)
            if (!mat_data.diffuse_texture.empty()) {
                mat.texture_path = base_dir + "/" + mat_data.diffuse_texture;
            }
            
            materials_.push_back(mat);
            material_name_to_index_[mat_data.name] = static_cast<int>(i);
        }
        
        grassland::LogInfo("Loaded {} materials from MTL file", materials_.size());
    }
    else grassland::LogInfo("MTL file not detected");
    
    if (has_uv_coords_) {
        grassland::LogInfo("Successfully loaded mesh: {} ({} vertices, {} indices, {} UV coords)", 
                          obj_file_path, mesh_.NumVertices(), mesh_.NumIndices(), mesh_.NumVertices());
    } else {
        grassland::LogInfo("Successfully loaded mesh: {} ({} vertices, {} indices, no UV coords)", 
                          obj_file_path, mesh_.NumVertices(), mesh_.NumIndices());
    }
    grassland::LogInfo("Till now, has_material_ids= {}" ,has_material_ids_);
    mesh_loaded_ = true;
    return true;
}

void Entity::BuildBLAS(grassland::graphics::Core* core) {
    if (!mesh_loaded_) {
        grassland::LogError("Cannot build BLAS: mesh not loaded");
        return;
    }

    // Create vertex buffer
    size_t vertex_buffer_size = mesh_.NumVertices() * sizeof(glm::vec3);
    core->CreateBuffer(vertex_buffer_size, 
                      grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                      &vertex_buffer_);
    vertex_buffer_->UploadData(mesh_.Positions(), vertex_buffer_size);

    // Create index buffer
    size_t index_buffer_size = mesh_.NumIndices() * sizeof(uint32_t);
    core->CreateBuffer(index_buffer_size, 
                      grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                      &index_buffer_);
    index_buffer_->UploadData(mesh_.Indices(), index_buffer_size);

    // Create UV buffer if UV coordinates exist
    if (has_uv_coords_) {
        size_t uv_buffer_size = mesh_.NumVertices() * sizeof(glm::vec2);
        core->CreateBuffer(uv_buffer_size,
                          grassland::graphics::BUFFER_TYPE_DYNAMIC,
                          &uv_buffer_);
        uv_buffer_->UploadData(mesh_.TexCoords(), uv_buffer_size);
        grassland::LogInfo("Created UV buffer with {} texture coordinates", mesh_.NumVertices());
    } else {
        grassland::LogInfo("No UV coordinates in mesh, skipping UV buffer creation");
    }

    // Create material ID buffer if material IDs exist
    if (has_material_ids_) {
        size_t num_triangles = mesh_.NumIndices() / 3;
        
        // Apply material offset to create global material IDs
        std::vector<int> global_material_ids;
        global_material_ids.reserve(num_triangles);
        
        const int* local_material_ids = mesh_.MaterialIds();
        for (size_t i = 0; i < num_triangles; ++i) {
            global_material_ids.push_back(local_material_ids[i] + material_offset_);
        }
        
        size_t material_id_buffer_size = num_triangles * sizeof(int);
        core->CreateBuffer(material_id_buffer_size,
                          grassland::graphics::BUFFER_TYPE_DYNAMIC,
                          &material_id_buffer_);
        material_id_buffer_->UploadData(global_material_ids.data(), material_id_buffer_size);
        grassland::LogInfo("Created material ID buffer with {} triangles (offset: {})", 
                          num_triangles, material_offset_);
    } else {
        grassland::LogInfo("No material IDs in mesh, skipping material ID buffer creation");
    }

    // Build BLAS
    core->CreateBottomLevelAccelerationStructure(
        vertex_buffer_.get(), 
        index_buffer_.get(), 
        sizeof(glm::vec3), 
        &blas_);

    grassland::LogInfo("Built BLAS for entity");
}

const Material* Entity::GetMaterial(const std::string& name) const {
    auto it = material_name_to_index_.find(name);
    if (it != material_name_to_index_.end()) {
        return &materials_[it->second];
    }
    return nullptr;
}

const Material* Entity::GetMaterial(int index) const {
    if (index >= 0 && index < static_cast<int>(materials_.size())) {
        return &materials_[index];
    }
    return nullptr;
}

