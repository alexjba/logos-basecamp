# Impure half: the Xcode-generator link of the smoke host, driven by
# `nix run .#run-liblogos-ios-sim` / `run-liblogos-ios-device`.
cmake_minimum_required(VERSION 3.24)
project(LiblogosSmokeIos LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Network RemoteObjects)
qt_standard_project_setup(REQUIRES 6.5)
find_package(LiblogosSmokeHost CONFIG REQUIRED)

qt_add_executable(LiblogosSmoke MACOSX_BUNDLE ${CMAKE_CURRENT_SOURCE_DIR}/../src/main.cpp)
qt_add_resources(LiblogosSmoke "smoke_web" PREFIX "/web"
    BASE ${CMAKE_CURRENT_SOURCE_DIR}/../web
    FILES ${CMAKE_CURRENT_SOURCE_DIR}/../web/index.html)
target_link_libraries(LiblogosSmoke PRIVATE Logos::SmokeHost Qt6::Widgets)
# Static Qt plugin registration (Q_IMPORT_PLUGIN of the counter module) lives
# in an archive member nothing references: force it in.
target_link_options(LiblogosSmoke PRIVATE
    "LINKER:-force_load,$<TARGET_FILE:Logos::SmokeHost>")

set_target_properties(LiblogosSmoke PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/../Info.plist.in
    MACOSX_BUNDLE_GUI_IDENTIFIER co.logos.spike.liblogos
    MACOSX_BUNDLE_BUNDLE_NAME "Liblogos Smoke"
    MACOSX_BUNDLE_BUNDLE_VERSION 1
    MACOSX_BUNDLE_SHORT_VERSION_STRING 0.1
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER co.logos.spike.liblogos
)

set(SPIKE_IOS_DEVELOPMENT_TEAM "" CACHE STRING "Apple development team id for automatic signing")
if(SPIKE_IOS_DEVELOPMENT_TEAM)
    set_target_properties(LiblogosSmoke PROPERTIES
        XCODE_ATTRIBUTE_CODE_SIGN_STYLE Automatic
        XCODE_ATTRIBUTE_DEVELOPMENT_TEAM ${SPIKE_IOS_DEVELOPMENT_TEAM})
else()
    set_target_properties(LiblogosSmoke PROPERTIES
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
        XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO
        XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "")
endif()
