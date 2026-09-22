/// Determines which types of nodes the plugin supports
enum NodeType {
  /// Node with a renderable with file ending `.gltf` in the Flutter asset folder
  localGLTF2,

  /// Node with a renderable with file ending `.glb` loaded from the internet during runtime
  webGLB,

  /// Node with a renderable with file ending `.glb` in the documents folder of the current app
  fileSystemAppFolderGLB,

  /// Node with a renderable with file ending `.gltf` in the documents folder of the current app
  fileSystemAppFolderGLTF2,
}
