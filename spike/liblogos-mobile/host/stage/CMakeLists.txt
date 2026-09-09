# Pure half of the liblogos smoke host: everything except main.cpp, built as a
# static archive by nix (pkgs.mkIosCmakeStage). The exported target carries
# every Logos/third-party archive as an absolute path so the Xcode-generated
# app only has to link Logos::SmokeHost.
cmake_minimum_required(VERSION 3.24)
project(LiblogosSmokeHost LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Network RemoteObjects)

# Roots whose lib/*.a are linked into the app, and whose include/ is visible
# here. Passed by nix as a ;-list.
set(LOGOS_IOS_LIB_ROOTS "" CACHE STRING "Prefixes holding lib/*.a to link")
set(LOGOS_IOS_INCLUDE_ROOTS "" CACHE STRING "Prefixes holding include/ to compile against")

set(SRC ${CMAKE_CURRENT_SOURCE_DIR}/../src)
add_library(liblogos_smoke_host STATIC
    ${SRC}/SmokeRunner.cpp
    ${SRC}/SmokeRunner.h
    ${SRC}/CounterModule.cpp
    ${SRC}/CounterModule.h
    ${SRC}/WebRelay.mm
    ${SRC}/WebRelay.h
    ${SRC}/JsonRpc.cpp
    ${SRC}/JsonRpc.h
)
# moc emits qt_static_plugin_CounterModule() (what Q_IMPORT_PLUGIN resolves)
# only when the plugin is compiled as a static one.
target_compile_definitions(liblogos_smoke_host PRIVATE QT_STATICPLUGIN)
target_include_directories(liblogos_smoke_host PUBLIC
    $<BUILD_INTERFACE:${SRC}>
    $<INSTALL_INTERFACE:include/liblogos-smoke-host>)
foreach(_root IN LISTS LOGOS_IOS_INCLUDE_ROOTS)
    foreach(_inc include include/cpp include/core include/implementations/plain include/logos_container include/logos_module_loader include/process_stats)
        if(IS_DIRECTORY "${_root}/${_inc}")
            target_include_directories(liblogos_smoke_host PUBLIC "${_root}/${_inc}")
        endif()
    endforeach()
endforeach()

# Static archives: the linker resolves across archives in any order (ld-prime),
# so a flat list is enough. liblogos_core first so its undefined symbols pull
# the rest in.
set(_archives "")
foreach(_root IN LISTS LOGOS_IOS_LIB_ROOTS)
    file(GLOB _found "${_root}/lib/*.a")
    list(APPEND _archives ${_found})
endforeach()
list(FILTER _archives EXCLUDE REGEX "liblgx_core\\.a$")  # liblgx.a already carries it
set(_core "")
foreach(_a IN LISTS _archives)
    if(_a MATCHES "liblogos_core\\.a$")
        set(_core ${_a})
    endif()
endforeach()
list(REMOVE_ITEM _archives ${_core})
list(PREPEND _archives ${_core})
message(STATUS "Logos archives: ${_archives}")

target_link_libraries(liblogos_smoke_host PUBLIC
    ${_archives}
    Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Network Qt6::RemoteObjects
    z
    "-framework CoreFoundation"
    "-framework Foundation"
    "-framework WebKit"
)

set_target_properties(liblogos_smoke_host PROPERTIES EXPORT_NAME SmokeHost)
install(TARGETS liblogos_smoke_host EXPORT LiblogosSmokeHostTargets ARCHIVE DESTINATION lib)
install(FILES ${SRC}/SmokeRunner.h ${SRC}/CounterModule.h ${SRC}/WebRelay.h ${SRC}/JsonRpc.h
    DESTINATION include/liblogos-smoke-host)
install(EXPORT LiblogosSmokeHostTargets
    FILE LiblogosSmokeHostTargets.cmake NAMESPACE Logos::
    DESTINATION lib/cmake/LiblogosSmokeHost)
file(CONFIGURE OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/LiblogosSmokeHostConfig.cmake CONTENT [[
include(CMakeFindDependencyMacro)
find_dependency(Qt6 COMPONENTS Core Gui Widgets Network RemoteObjects)
include("${CMAKE_CURRENT_LIST_DIR}/LiblogosSmokeHostTargets.cmake")
]] @ONLY)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/LiblogosSmokeHostConfig.cmake
    DESTINATION lib/cmake/LiblogosSmokeHost)
