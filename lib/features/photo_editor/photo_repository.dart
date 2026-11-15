import 'package:flutter/services.dart';

class PhotoRecipe {
  const PhotoRecipe({
    this.exposure = 0,
    this.contrast = 1,
    this.saturation = 1,
    this.warmth = 0,
    this.highlights = 0,
    this.shadows = 0,
  });
  factory PhotoRecipe.fromMap(Map<String, dynamic> map) => PhotoRecipe(
    exposure: (map['exposure'] as num?)?.toDouble() ?? 0,
    contrast: (map['contrast'] as num?)?.toDouble() ?? 1,
    saturation: (map['saturation'] as num?)?.toDouble() ?? 1,
    warmth: (map['warmth'] as num?)?.toDouble() ?? 0,
    highlights: (map['highlights'] as num?)?.toDouble() ?? 0,
    shadows: (map['shadows'] as num?)?.toDouble() ?? 0,
  );
  final double exposure, contrast, saturation, warmth, highlights, shadows;
  Map<String, double> toMap() => {
    'exposure': exposure,
    'contrast': contrast,
    'saturation': saturation,
    'warmth': warmth,
    'highlights': highlights,
    'shadows': shadows,
  };
  PhotoRecipe copyWith({
    double? exposure,
    double? contrast,
    double? saturation,
    double? warmth,
    double? highlights,
    double? shadows,
  }) => PhotoRecipe(
    exposure: exposure ?? this.exposure,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
    warmth: warmth ?? this.warmth,
    highlights: highlights ?? this.highlights,
    shadows: shadows ?? this.shadows,
  );
  @override
  bool operator ==(Object other) =>
      other is PhotoRecipe &&
      exposure == other.exposure &&
      contrast == other.contrast &&
      saturation == other.saturation &&
      warmth == other.warmth &&
      highlights == other.highlights &&
      shadows == other.shadows;
  @override
  int get hashCode =>
      Object.hash(exposure, contrast, saturation, warmth, highlights, shadows);
}

abstract interface class PhotoRepository {
  Future<PhotoRecipe> loadRecipe(String path);
  Future<void> saveRecipe(String path, PhotoRecipe recipe);
  Future<Uint8List> preview(String path, PhotoRecipe recipe);
  Future<PhotoRecipe> autoRecipe(String path);
  Future<String> export(
    String path,
    PhotoRecipe recipe, {
    bool preserveExif = false,
  });
  Future<void> saveToPhotos(String exportedPath);
  Future<Map<String, dynamic>> analyze(
    String path,
    PhotoRecipe recipe,
    String goal,
  );
}

class NativePhotoRepository implements PhotoRepository {
  static const channel = MethodChannel('com.parado.canoneos/photo');
  Map<String, dynamic> args(String path, [PhotoRecipe? recipe]) => {
    'path': path,
    if (recipe != null) 'recipe': recipe.toMap(),
  };
  @override
  Future<PhotoRecipe> loadRecipe(String path) async => PhotoRecipe.fromMap(
    Map<String, dynamic>.from(
      await channel.invokeMapMethod('loadRecipe', args(path)) ?? {},
    ),
  );
  @override
  Future<void> saveRecipe(String path, PhotoRecipe recipe) async =>
      channel.invokeMethod<void>('saveRecipe', args(path, recipe));
  @override
  Future<Uint8List> preview(String path, PhotoRecipe recipe) async =>
      (await channel.invokeMethod<Uint8List>('preview', args(path, recipe)))!;
  @override
  Future<PhotoRecipe> autoRecipe(String path) async => PhotoRecipe.fromMap(
    Map<String, dynamic>.from(
      await channel.invokeMapMethod('autoRecipe', args(path)) ?? {},
    ),
  );
  @override
  Future<String> export(
    String path,
    PhotoRecipe recipe, {
    bool preserveExif = false,
  }) async =>
      (await channel.invokeMethod<String>('export', {
        ...args(path, recipe),
        if (preserveExif) 'preserveExif': true,
      }))!;
  @override
  Future<void> saveToPhotos(String exportedPath) =>
      channel.invokeMethod<void>('saveToPhotos', args(exportedPath));
  @override
  Future<Map<String, dynamic>> analyze(
    String path,
    PhotoRecipe recipe,
    String goal,
  ) async => Map<String, dynamic>.from(
    await channel.invokeMapMethod('analyzePhoto', {
          ...args(path, recipe),
          'goal': goal,
        }) ??
        {},
  );
}
