#include "Scene.h"

// Include stb_image for texture loading
#include "stb_image.h"

Scene::Scene(grassland::graphics::Core* core)
    : core_(core) {
}

Scene::~Scene() {
    Clear();
}

void Scene::AddEntity(std::shared_ptr<Entity> entity) {
    if (!entity || !entity->IsValid()) {
        grassland::LogError("Cannot add invalid entity to scene");
        return;
    }

    // Build BLAS for the entity
    entity->BuildBLAS(core_);
    
    entities_.push_back(entity);
    grassland::LogInfo("Added entity to scene (total: {})", entities_.size());
}

void Scene::AddPointLight(const PointLight & light) {
    point_lights_. push_back(light);
}

void Scene::Clear() {
    entities_.clear();
    tlas_.reset();
    materials_buffer_.reset();
    textures_.clear();
    texture_path_to_index_.clear();
}

void Scene::BuildAccelerationStructures() {
    if (entities_.empty()) {
        grassland::LogWarning("No entities to build acceleration structures");
        return;
    }

    // Create TLAS instances from all entities
    std::vector<grassland::graphics::RayTracingInstance> instances;
    instances.reserve(entities_.size());

    for (size_t i = 0; i < entities_.size(); ++i) {
        auto& entity = entities_[i];
        if (entity->GetBLAS()) {
            // Create instance with entity's transform
            // instanceCustomIndex is used to index into materials buffer
            // Convert mat4 to mat4x3 (drop the last row which is always [0,0,0,1] for affine transforms)
            glm::mat4x3 transform_3x4 = glm::mat4x3(entity->GetTransform());
            
            auto instance = entity->GetBLAS()->MakeInstance(
                transform_3x4,
                static_cast<uint32_t>(i),  // instanceCustomIndex for material lookup
                0xFF,                       // instanceMask
                0,                          // instanceShaderBindingTableRecordOffset
                grassland::graphics::RAYTRACING_INSTANCE_FLAG_NONE
            );
            instances.push_back(instance);
        }
    }

    // Build TLAS
    core_->CreateTopLevelAccelerationStructure(instances, &tlas_);
    grassland::LogInfo("Built TLAS with {} instances", instances.size());

    // Assign material offsets to entities
    AssignMaterialOffsets();

    // Load textures and assign indices to materials
    AssignTextureIndices();

    // Build global UV and material ID buffers
    ConstructUVBuffer();
    ConstructMaterialIDBuffer();
    ConstructIndexBuffer();
    
    // Build instance metadata buffer
    ConstructInstanceMetadataBuffer();

    // Update materials buffer
    UpdateMaterialsBuffer();
}

void Scene::UpdateInstances() {
    if (!tlas_ || entities_.empty()) {
        return;
    }

    // Recreate instances with updated transforms
    std::vector<grassland::graphics::RayTracingInstance> instances;
    instances.reserve(entities_.size());

    for (size_t i = 0; i < entities_.size(); ++i) {
        auto& entity = entities_[i];
        if (entity->GetBLAS()) {
            // Convert mat4 to mat4x3
            glm::mat4x3 transform_3x4 = glm::mat4x3(entity->GetTransform());
            
            auto instance = entity->GetBLAS()->MakeInstance(
                transform_3x4,
                static_cast<uint32_t>(i),
                0xFF,
                0,
                grassland::graphics::RAYTRACING_INSTANCE_FLAG_NONE
            );
            instances.push_back(instance);
        }
    }

    // Update TLAS
    tlas_->UpdateInstances(instances);
}

void Scene::AssignMaterialOffsets() {
    int global_material_offset = 0;
    
    for (auto& entity : entities_) {
        entity->SetMaterialOffset(global_material_offset);
        
        if (entity->HasMTLMaterials()) {
            global_material_offset += entity->GetMaterials().size();
        } else {
            global_material_offset += 1;  // Default material
        }
    }
    
    grassland::LogInfo("Assigned material offsets to {} entities, total {} materials", 
                     entities_.size(), global_material_offset);
}

void Scene::UpdateMaterialsBuffer() {
    if (entities_.empty()) {
        return;
    }

    // Collect all materials in GPU format
    // Each entity's materials are appended to create a global material array
    std::vector<MaterialGPUData> materials;

    for (const auto& entity : entities_) {
        if (entity->HasMTLMaterials()) {
            // Add all materials from MTL
            auto& mtl_materials = entity->GetMaterials();
            for (const auto& mat : mtl_materials) {
                materials.push_back(mat.ToGPUData());
            }
        } else {
            // Add default material
            materials.push_back(entity->GetDefaultMaterial().ToGPUData());
        }
    }

    // Create/update materials buffer
    size_t buffer_size = materials.size() * sizeof(MaterialGPUData);
    
    if (!materials_buffer_) {
        core_->CreateBuffer(buffer_size, 
                          grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                          &materials_buffer_);
    }
    
    materials_buffer_->UploadData(materials.data(), buffer_size);
    grassland::LogInfo("Updated materials buffer with {} materials", materials.size());
}

void Scene::AssignTextureIndices() {
    // Load all unique textures and assign indices to materials (assign texture and normal maps together)
    int cnt = 0;
    grassland::LogInfo("AAAAA Assigning Texture index to entity {}", cnt);
    for (auto& entity : entities_) {
        if (entity->HasMTLMaterials()) {
            // Process all materials from MTL
            auto& mtl_materials = entity->GetMutableMaterials();
            for (size_t i = 0; i < mtl_materials.size(); ++i) {
                Material& mat = mtl_materials[i];
                if (mat.HasTexture()) {
                    int tex_index = LoadTexture(mat.GetTexturePath());
                    mat.texture_index = tex_index;
                    grassland::LogInfo("Assigned texture index {} to material {} with texture: {}", 
                                     tex_index, i, mat.GetTexturePath());
                }
                if(mat.HasNormal()) {
                    int norm_index = LoadNormal(mat.GetNormalPath());
                    mat.normal_index = norm_index; 
                    grassland::LogInfo("Assigned texture index {} to material {} with texture: {}", 
                                     norm_index, i, mat.GetNormalPath());
                }
            }
            grassland::LogInfo("Entity {} has texture index {}", cnt, mtl_materials[0].texture_index);

        } else {
            // Process default material
            Material& mat = entity->GetMutableDefaultMaterial();
            if (mat.HasTexture()) {
                int tex_index = LoadTexture(mat.GetTexturePath());
                mat.texture_index = tex_index;
                grassland::LogInfo("Assigned texture index {} to default material with texture: {}", 
                                 tex_index, mat.GetTexturePath());
            }
            if(mat.HasNormal()) {
                int norm_index = LoadNormal(mat.GetNormalPath());
                mat.normal_index = norm_index; 
                grassland::LogInfo("Assigned texture index {} to material {} with texture: {}", 
                                    norm_index, mat.GetNormalPath());
            }
            grassland::LogInfo("Entity {} has texture index {}", cnt, mat.texture_index);
        }
        
        cnt++;
    }
}

int Scene::LoadTexture(const std::string& filepath) {
    // Check if already loaded
    grassland::LogInfo("Entering Texture Loading");
    auto it = texture_path_to_index_.find(filepath);
    if (it != texture_path_to_index_.end()) {
        return it->second;
    }

    // Load image using stb_image
    int width, height, channels;
    unsigned char* data = stbi_load(filepath.c_str(), &width, &height, &channels, 4);  // Force RGBA
    
    if (!data) {
        grassland::LogInfo("Failed to load texture: {} - {}", filepath, stbi_failure_reason());
        return -1;
    }
    grassland::LogInfo("Successfully Loaded Texture");
    // Create GPU image
    std::unique_ptr<grassland::graphics::Image> texture;
    core_->CreateImage(
        width,
        height,
        grassland::graphics::IMAGE_FORMAT_R8G8B8A8_UNORM,
        &texture
    );

    // Upload data
    texture->UploadData(data);
    
    // Free image data
    stbi_image_free(data);

    // Store texture
    int index = static_cast<int>(textures_.size());
    textures_.push_back(std::move(texture));
    texture_path_to_index_[filepath] = index;

    grassland::LogInfo("Loaded texture: {} ({}x{}, {} channels) -> index {}", 
                      filepath, width, height, channels, index);

    return index;
}

int Scene::LoadNormal(const std::string& filepath){
    grassland::LogInfo("Enter Normal Loading");
    int width, height, channels;
    unsigned char* data = stbi_load(filepath.c_str(), &width, &height, &channels, 4);  // Force RGBA
    
    if (!data) {
        grassland::LogInfo("Failed to load normal: {} - {}", filepath, stbi_failure_reason());
        return -1;
    }
    grassland::LogInfo("Successfully Loaded normal");
    // Create GPU image
    std::unique_ptr<grassland::graphics::Image> normal;
    core_->CreateImage(
        width,
        height,
        grassland::graphics::IMAGE_FORMAT_R8G8B8A8_UNORM,
        &normal
    );

    // Upload data
    normal->UploadData(data);
    
    // Free image data
    stbi_image_free(data);

    // Store texture
    int index = static_cast<int>(normals_.size());
    normals_.push_back(std::move(normal));

    grassland::LogInfo("Loaded normal: {} ({}x{}, {} channels) -> index {}", 
                      filepath, width, height, channels, index);

    return index;
}


void Scene::ConstructUVBuffer(){
    if(entities_.empty()){
        return;
    }
    
    std::vector<glm::vec2> global_uv;
    
    // Calculate total vertices (only for entities with UV)
    size_t total_vertices = 0;
    for(const auto& entity : entities_){
        if(entity->HasUVCoordinates()){
            total_vertices += entity->GetNumVertices();
        }
    }
    
    // Reserve space to avoid reallocation
    global_uv.reserve(total_vertices);
    
    // Collect UV data from entities that have UV coordinates
    for(const auto& entity : entities_){
        if(entity->HasUVCoordinates()){
            auto* uv_data = entity->GetUVCoordinates();
            size_t count = entity->GetNumVertices();
            
            // Convert from Eigen::Vector2<float> to glm::vec2
            for(size_t i = 0; i < count; i++) {
                global_uv.push_back(glm::vec2(uv_data[i][0], uv_data[i][1]));
            }
        }
        // No padding for entities without UV - metadata will handle this
    }
    
    // Create GPU buffer if we have UV data
    if(!global_uv.empty()){
        size_t buffer_size = global_uv.size() * sizeof(glm::vec2);
        core_->CreateBuffer(buffer_size,
                           grassland::graphics::BUFFER_TYPE_DYNAMIC,
                           &global_uv_buffer_);
        global_uv_buffer_->UploadData(global_uv.data(), buffer_size);
        
        grassland::LogInfo("Created global UV buffer with {} UV coordinates (no padding)", 
                          global_uv.size());
    }
}

void Scene::ConstructMaterialIDBuffer(){
    if(entities_.empty()){
        return;
    }
    
    std::vector<int> global_material_ids;
    
    // Calculate total triangles (only for entities with material IDs)
    size_t total_triangles = 0;
    for(const auto& entity : entities_){
        if(entity->HasMaterialIDs()){
            total_triangles += entity->GetNumTriangles();
        }
    }
    
    // Reserve space to avoid reallocation
    global_material_ids.reserve(total_triangles);
    
    // Collect material ID data from entities that have material IDs
    for(const auto& entity : entities_){
        if(entity->HasMaterialIDs()){
            const int* material_ids = entity->GetMaterialIDs();
            size_t num_triangles = entity->GetNumTriangles();
            int material_offset = entity->GetMaterialOffset();
            
            // Add material offset to convert local IDs to global IDs
            for(size_t i = 0; i < num_triangles; i++) {
                global_material_ids.push_back(material_ids[i] + material_offset);
            }
            grassland::LogInfo("This entity has material IDs {} and offset {}", entity->HasMaterialIDs(), material_offset);
        }
        else grassland::LogInfo("This entity does not have material ID");
        // No padding for entities without material IDs - metadata will handle this
    }
    
    // Create GPU buffer if we have material ID data
    if(!global_material_ids.empty()){
        size_t buffer_size = global_material_ids.size() * sizeof(int);
        core_->CreateBuffer(buffer_size,
                           grassland::graphics::BUFFER_TYPE_DYNAMIC,
                           &global_material_id_buffer_);
        global_material_id_buffer_->UploadData(global_material_ids.data(), buffer_size);
        
        grassland::LogInfo("Created global Material ID buffer with {} material IDs (no padding)", 
                          global_material_ids.size());
    }
}

void Scene::ConstructIndexBuffer(){
    if(entities_.empty()){
        return;
    }
    
    std::vector<uint32_t> global_indices;
    
    // Calculate total indices
    size_t total_indices = 0;
    for(const auto& entity : entities_){
        total_indices += entity->GetNumIndices();
    }
    
    // Reserve space to avoid reallocation
    global_indices.reserve(total_indices);
    
    // Collect index data from all entities
    for(const auto& entity : entities_){
        const uint32_t* indices = entity->GetIndices();
        size_t num_indices = entity->GetNumIndices();
        
        // Copy indices directly (no offset adjustment needed - UV buffer already handles vertex offsets)
        for(size_t i = 0; i < num_indices; i++) {
            global_indices.push_back(indices[i]);
        }
    }
    grassland::LogInfo("Pending global index buffer creating with {} indices", global_indices.size());
    // Create GPU buffer if we have index data
    if(!global_indices.empty()){
        size_t buffer_size = global_indices.size() * sizeof(uint32_t);
        core_->CreateBuffer(buffer_size,
                           grassland::graphics::BUFFER_TYPE_DYNAMIC,
                           &global_index_buffer_);
        global_index_buffer_->UploadData(global_indices.data(), buffer_size);
        
        grassland::LogInfo("Created global index buffer with {} indices", 
                          global_indices.size());
    }
}

void Scene::ConstructInstanceMetadataBuffer(){
    if(entities_.empty()){
        return;
    }
    
    instance_metadata_.clear();
    instance_metadata_.reserve(entities_.size());
    
    int uv_offset = 0;
    int mat_id_offset = 0;
    int index_offset = 0;  // Track index buffer offset
    
    for(const auto& entity : entities_){
        InstanceMetadata metadata;
        metadata.padding[0] = 0;
        
        // UV information
        if(entity->HasUVCoordinates()){
            metadata.uv_offset = uv_offset;
            metadata.has_uv = 1;
            metadata.vertex_count = static_cast<int>(entity->GetNumVertices());
            uv_offset += metadata.vertex_count;
        } else {
            metadata.uv_offset = -1;  // Mark as no UV
            metadata.has_uv = 0;
            metadata.vertex_count = 0;
        }
        
        // Material ID information
        if(entity->HasMaterialIDs()){
            metadata.material_id_offset = mat_id_offset;
            metadata.has_material_ids = 1;
            metadata.triangle_count = static_cast<int>(entity->GetNumTriangles());
            mat_id_offset += metadata.triangle_count;
        } else {
            // No material IDs - use material offset directly as the material index
            metadata.material_id_offset = entity->GetMaterialOffset();
            metadata.has_material_ids = 0;
            metadata.triangle_count = 0;
        }
        
        // Index buffer offset
        metadata.index_offset = index_offset;
        index_offset += static_cast<int>(entity->GetNumIndices());
        
        instance_metadata_.push_back(metadata);
    }
    
    // Create GPU buffer
    size_t buffer_size = instance_metadata_.size() * sizeof(InstanceMetadata);
    core_->CreateBuffer(buffer_size,
                       grassland::graphics::BUFFER_TYPE_DYNAMIC,
                       &instance_metadata_buffer_);
    instance_metadata_buffer_->UploadData(instance_metadata_.data(), buffer_size);
    
    grassland::LogInfo("Created instance metadata buffer with {} entries", instance_metadata_.size());
}

grassland::graphics::Image* Scene::GetTexture(int index) const {
    if (index < 0 || index >= static_cast<int>(textures_.size())) {
        return nullptr;
    }
    return textures_[index].get();
}

grassland::graphics::Image* Scene::GetNormal(int index) const {
    if(index < 0 || index >= static_cast<int>(normals_.size())) {
        return nullptr;
    }
    return normals_[index].get();
}
