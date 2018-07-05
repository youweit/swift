//===--- TypeCheckDeclObjC.cpp - Type Checking for ObjC Declarations ------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// This file implements semantic analysis for Objective-C-specific
// aspects of declarations.
//
//===----------------------------------------------------------------------===//
#include "TypeCheckObjC.h"
#include "TypeChecker.h"
#include "swift/AST/ASTContext.h"
#include "swift/AST/Decl.h"
#include "swift/AST/ExistentialLayout.h"
#include "swift/AST/ForeignErrorConvention.h"
#include "swift/AST/ParameterList.h"
#include "swift/Basic/StringExtras.h"
using namespace swift;

#pragma mark Determine whether an entity is representable in Objective-C.

bool swift::shouldDiagnoseObjCReason(ObjCReason reason, ASTContext &ctx) {
  switch(reason) {
  case ObjCReason::ExplicitlyCDecl:
  case ObjCReason::ExplicitlyDynamic:
  case ObjCReason::ExplicitlyObjC:
  case ObjCReason::ExplicitlyIBOutlet:
  case ObjCReason::ExplicitlyIBAction:
  case ObjCReason::ExplicitlyNSManaged:
  case ObjCReason::MemberOfObjCProtocol:
  case ObjCReason::OverridesObjC:
  case ObjCReason::WitnessToObjC:
  case ObjCReason::ImplicitlyObjC:
  case ObjCReason::MemberOfObjCExtension:
    return true;

  case ObjCReason::ExplicitlyIBInspectable:
  case ObjCReason::ExplicitlyGKInspectable:
    return !ctx.LangOpts.EnableSwift3ObjCInference;

  case ObjCReason::MemberOfObjCSubclass:
  case ObjCReason::MemberOfObjCMembersClass:
  case ObjCReason::Accessor:
    return false;
  }
}

unsigned swift::getObjCDiagnosticAttrKind(ObjCReason reason) {
  switch (reason) {
  case ObjCReason::ExplicitlyCDecl:
  case ObjCReason::ExplicitlyDynamic:
  case ObjCReason::ExplicitlyObjC:
  case ObjCReason::ExplicitlyIBOutlet:
  case ObjCReason::ExplicitlyIBAction:
  case ObjCReason::ExplicitlyNSManaged:
  case ObjCReason::MemberOfObjCProtocol:
  case ObjCReason::OverridesObjC:
  case ObjCReason::WitnessToObjC:
  case ObjCReason::ImplicitlyObjC:
  case ObjCReason::ExplicitlyIBInspectable:
  case ObjCReason::ExplicitlyGKInspectable:
  case ObjCReason::MemberOfObjCExtension:
    return static_cast<unsigned>(reason);

  case ObjCReason::MemberOfObjCSubclass:
  case ObjCReason::MemberOfObjCMembersClass:
  case ObjCReason::Accessor:
    llvm_unreachable("should not diagnose this @objc reason");
  }
}

/// Emit an additional diagnostic describing why we are applying @objc to the
/// decl, if this is not obvious from the decl itself.
static void describeObjCReason(const ValueDecl *VD, ObjCReason Reason) {
  if (Reason == ObjCReason::MemberOfObjCProtocol) {
    VD->diagnose(diag::objc_inferring_on_objc_protocol_member);
  } else if (Reason == ObjCReason::OverridesObjC) {
    unsigned kind = isa<VarDecl>(VD) ? 0
                  : isa<SubscriptDecl>(VD) ? 1
                  : isa<ConstructorDecl>(VD) ? 2
                  : 3;

    auto overridden = VD->getOverriddenDecl();
    overridden->diagnose(diag::objc_overriding_objc_decl,
                         kind, VD->getOverriddenDecl()->getFullName());
  } else if (Reason == ObjCReason::WitnessToObjC) {
    auto requirement = Reason.getObjCRequirement();
    requirement->diagnose(diag::objc_witness_objc_requirement,
                VD->getDescriptiveKind(), requirement->getFullName(),
                cast<ProtocolDecl>(requirement->getDeclContext())
                  ->getFullName());
  }
}

static void diagnoseTypeNotRepresentableInObjC(const DeclContext *DC,
                                               Type T,
                                               SourceRange TypeRange) {
  auto &diags = DC->getASTContext().Diags;

  // Special diagnostic for tuples.
  if (T->is<TupleType>()) {
    if (T->isVoid())
      diags.diagnose(TypeRange.Start, diag::not_objc_empty_tuple)
          .highlight(TypeRange);
    else
      diags.diagnose(TypeRange.Start, diag::not_objc_tuple)
          .highlight(TypeRange);
    return;
  }

  // Special diagnostic for classes.
  if (auto *CD = T->getClassOrBoundGenericClass()) {
    if (!CD->isObjC())
      diags.diagnose(TypeRange.Start, diag::not_objc_swift_class)
          .highlight(TypeRange);
    return;
  }

  // Special diagnostic for structs.
  if (T->is<StructType>()) {
    diags.diagnose(TypeRange.Start, diag::not_objc_swift_struct)
        .highlight(TypeRange);
    return;
  }

  // Special diagnostic for enums.
  if (T->is<EnumType>()) {
    diags.diagnose(TypeRange.Start, diag::not_objc_swift_enum)
        .highlight(TypeRange);
    return;
  }

  // Special diagnostic for protocols and protocol compositions.
  if (T->isExistentialType()) {
    if (T->isAny()) {
      // Any is not @objc.
      diags.diagnose(TypeRange.Start,
                     diag::not_objc_empty_protocol_composition);
      return;
    }

    auto layout = T->getExistentialLayout();

    // See if the superclass is not @objc.
    if (auto superclass = layout.explicitSuperclass) {
      if (!superclass->getClassOrBoundGenericClass()->isObjC()) {
        diags.diagnose(TypeRange.Start, diag::not_objc_class_constraint,
                       superclass);
        return;
      }
    }

    // Find a protocol that is not @objc.
    bool sawErrorProtocol = false;
    for (auto P : layout.getProtocols()) {
      auto *PD = P->getDecl();

      if (PD->isSpecificProtocol(KnownProtocolKind::Error)) {
        sawErrorProtocol = true;
        break;
      }

      if (!PD->isObjC()) {
        diags.diagnose(TypeRange.Start, diag::not_objc_protocol,
                       PD->getDeclaredType());
        return;
      }
    }

    if (sawErrorProtocol) {
      diags.diagnose(TypeRange.Start,
                     diag::not_objc_error_protocol_composition);
      return;
    }

    return;
  }

  if (T->is<ArchetypeType>() || T->isTypeParameter()) {
    diags.diagnose(TypeRange.Start, diag::not_objc_generic_type_param)
        .highlight(TypeRange);
    return;
  }

  if (auto fnTy = T->getAs<FunctionType>()) {
    if (fnTy->getExtInfo().throws() ) {
      diags.diagnose(TypeRange.Start, diag::not_objc_function_type_throwing)
        .highlight(TypeRange);
      return;
    }

    diags.diagnose(TypeRange.Start, diag::not_objc_function_type_param)
      .highlight(TypeRange);
    return;
  }
}

static void diagnoseFunctionParamNotRepresentable(
    const AbstractFunctionDecl *AFD, unsigned NumParams,
    unsigned ParamIndex, const ParamDecl *P, ObjCReason Reason) {
  if (!shouldDiagnoseObjCReason(Reason, AFD->getASTContext()))
    return;

  if (NumParams == 1) {
    AFD->diagnose(diag::objc_invalid_on_func_single_param_type,
                  getObjCDiagnosticAttrKind(Reason));
  } else {
    AFD->diagnose(diag::objc_invalid_on_func_param_type,
                  ParamIndex + 1, getObjCDiagnosticAttrKind(Reason));
  }
  if (P->hasType()) {
    Type ParamTy = P->getType();
    SourceRange SR;
    if (auto typeRepr = P->getTypeLoc().getTypeRepr())
      SR = typeRepr->getSourceRange();
    diagnoseTypeNotRepresentableInObjC(AFD, ParamTy, SR);
  }
  describeObjCReason(AFD, Reason);
}

static bool isParamListRepresentableInObjC(const AbstractFunctionDecl *AFD,
                                           const ParameterList *PL,
                                           ObjCReason Reason) {
  // If you change this function, you must add or modify a test in PrintAsObjC.
  ASTContext &ctx = AFD->getASTContext();
  auto &diags = ctx.Diags;

  bool Diagnose = shouldDiagnoseObjCReason(Reason, ctx);
  bool IsObjC = true;
  unsigned NumParams = PL->size();
  for (unsigned ParamIndex = 0; ParamIndex != NumParams; ParamIndex++) {
    auto param = PL->get(ParamIndex);

    // Swift Varargs are not representable in Objective-C.
    if (param->isVariadic()) {
      if (Diagnose && shouldDiagnoseObjCReason(Reason, ctx)) {
        diags.diagnose(param->getStartLoc(), diag::objc_invalid_on_func_variadic,
                       getObjCDiagnosticAttrKind(Reason))
          .highlight(param->getSourceRange());
        describeObjCReason(AFD, Reason);
      }

      return false;
    }

    // Swift inout parameters are not representable in Objective-C.
    if (param->isInOut()) {
      if (Diagnose && shouldDiagnoseObjCReason(Reason, ctx)) {
        diags.diagnose(param->getStartLoc(), diag::objc_invalid_on_func_inout,
                       getObjCDiagnosticAttrKind(Reason))
          .highlight(param->getSourceRange());
        describeObjCReason(AFD, Reason);
      }

      return false;
    }

    if (param->getType()->isRepresentableIn(
          ForeignLanguage::ObjectiveC,
          const_cast<AbstractFunctionDecl *>(AFD)))
      continue;

    // Permit '()' when this method overrides a method with a
    // foreign error convention that replaces NSErrorPointer with ()
    // and this is the replaced parameter.
    AbstractFunctionDecl *overridden;
    if (param->getType()->isVoid() && AFD->hasThrows() &&
        (overridden = AFD->getOverriddenDecl())) {
      auto foreignError = overridden->getForeignErrorConvention();
      if (foreignError &&
          foreignError->isErrorParameterReplacedWithVoid() &&
          foreignError->getErrorParameterIndex() == ParamIndex) {
        continue;
      }
    }

    IsObjC = false;
    if (!Diagnose) {
      // Save some work and return as soon as possible if we are not
      // producing diagnostics.
      return IsObjC;
    }
    diagnoseFunctionParamNotRepresentable(AFD, NumParams, ParamIndex,
                                          param, Reason);
  }
  return IsObjC;
}

/// Check whether the given declaration contains its own generic parameters,
/// and therefore is not representable in Objective-C.
static bool checkObjCWithGenericParams(const AbstractFunctionDecl *AFD,
                                       ObjCReason Reason) {
  bool Diagnose = shouldDiagnoseObjCReason(Reason, AFD->getASTContext());

  if (AFD->getGenericParams()) {
    // Diagnose this problem, if asked to.
    if (Diagnose) {
      AFD->diagnose(diag::objc_invalid_with_generic_params,
                    getObjCDiagnosticAttrKind(Reason));
      describeObjCReason(AFD, Reason);
    }

    return true;
  }

  return false;
}

/// CF types cannot have @objc methods, because they don't have real class
/// objects.
static bool checkObjCInForeignClassContext(const ValueDecl *VD,
                                           ObjCReason Reason) {
  bool Diagnose = shouldDiagnoseObjCReason(Reason, VD->getASTContext());

  auto type = VD->getDeclContext()->getDeclaredInterfaceType();
  if (!type)
    return false;

  auto clas = type->getClassOrBoundGenericClass();
  if (!clas)
    return false;

  switch (clas->getForeignClassKind()) {
  case ClassDecl::ForeignKind::Normal:
    return false;

  case ClassDecl::ForeignKind::CFType:
    if (Diagnose) {
      VD->diagnose(diag::objc_invalid_on_foreign_class,
                   getObjCDiagnosticAttrKind(Reason));
      describeObjCReason(VD, Reason);
    }
    break;

  case ClassDecl::ForeignKind::RuntimeOnly:
    if (Diagnose) {
      VD->diagnose(diag::objc_in_objc_runtime_visible,
                   VD->getDescriptiveKind(), getObjCDiagnosticAttrKind(Reason),
                   clas->getName());
      describeObjCReason(VD, Reason);
    }
    break;
  }

  return true;
}

/// Check whether the given declaration occurs within a constrained
/// extension, or an extension of a class with generic ancestry, or an
/// extension of an Objective-C runtime visible class, and
/// therefore is not representable in Objective-C.
static bool checkObjCInExtensionContext(const ValueDecl *value,
                                        bool diagnose) {
  auto DC = value->getDeclContext();

  if (auto ED = dyn_cast<ExtensionDecl>(DC)) {
    if (ED->getTrailingWhereClause()) {
      if (diagnose) {
        value->diagnose(diag::objc_in_extension_context);
      }
      return true;
    }

    // Check if any Swift classes in the inheritance hierarchy have generic
    // parameters.
    // FIXME: This is a current limitation, not inherent. We don't have
    // a concrete class to attach Objective-C category metadata to.
    if (auto generic = ED->getDeclaredInterfaceType()
                           ->getGenericAncestor()) {
      if (!generic->getClassOrBoundGenericClass()->hasClangNode()) {
        if (diagnose) {
          value->diagnose(diag::objc_in_generic_extension);
        }
        return true;
      }
    }
  }

  return false;
}

bool TypeChecker::isCIntegerType(const DeclContext *DC, Type T) {
  if (CIntegerTypes.empty())
    fillObjCRepresentableTypeCache(DC);
  return CIntegerTypes.count(T->getCanonicalType());
}

/// Determines whether the given type is bridged to an Objective-C class type.
static bool isBridgedToObjectiveCClass(DeclContext *dc, Type type) {
  switch (type->getForeignRepresentableIn(ForeignLanguage::ObjectiveC, dc)
            .first) {
  case ForeignRepresentableKind::Trivial:
  case ForeignRepresentableKind::None:
    return false;

  case ForeignRepresentableKind::Object:
  case ForeignRepresentableKind::Bridged:
  case ForeignRepresentableKind::BridgedError:
  case ForeignRepresentableKind::StaticBridged:
    return true;
  }

  llvm_unreachable("Unhandled ForeignRepresentableKind in switch.");
}

bool TypeChecker::isRepresentableInObjC(
       const AbstractFunctionDecl *AFD,
       ObjCReason Reason,
       Optional<ForeignErrorConvention> &errorConvention) {
  // Clear out the error convention. It will be added later if needed.
  errorConvention = None;

  // If you change this function, you must add or modify a test in PrintAsObjC.

  bool Diagnose = shouldDiagnoseObjCReason(Reason, Context);

  if (checkObjCInForeignClassContext(AFD, Reason))
    return false;
  if (checkObjCWithGenericParams(AFD, Reason))
    return false;
  if (checkObjCInExtensionContext(AFD, Diagnose))
    return false;

  if (AFD->isOperator()) {
    diagnose(AFD, (isa<ProtocolDecl>(AFD->getDeclContext())
                   ? diag::objc_operator_proto
                   : diag::objc_operator));
    return false;
  }

  if (auto accessor = dyn_cast<AccessorDecl>(AFD)) {
    // Accessors can only be @objc if the storage declaration is.
    // Global computed properties may however @_cdecl their accessors.
    auto storage = accessor->getStorage();
    validateDecl(storage);
    if (!storage->isObjC() && Reason != ObjCReason::ExplicitlyCDecl &&
        Reason != ObjCReason::WitnessToObjC) {
      if (Diagnose) {
        auto error = accessor->isGetter()
                  ? (isa<VarDecl>(storage)
                       ? diag::objc_getter_for_nonobjc_property
                       : diag::objc_getter_for_nonobjc_subscript)
                  : (isa<VarDecl>(storage)
                       ? diag::objc_setter_for_nonobjc_property
                       : diag::objc_setter_for_nonobjc_subscript);

        diagnose(accessor->getLoc(), error);
        describeObjCReason(accessor, Reason);
      }
      return false;
    }

    switch (accessor->getAccessorKind()) {
    case AccessorKind::DidSet:
    case AccessorKind::WillSet:
        // willSet/didSet implementations are never exposed to objc, they are
        // always directly dispatched from the synthesized setter.
      if (Diagnose) {
        diagnose(accessor->getLoc(), diag::objc_observing_accessor);
        describeObjCReason(accessor, Reason);
      }
      return false;

    case AccessorKind::Get:
    case AccessorKind::Set:
      return true;

    case AccessorKind::MaterializeForSet:
      // materializeForSet is synthesized, so never complain about it
      return false;

    case AccessorKind::Address:
    case AccessorKind::MutableAddress:
      if (Diagnose) {
        diagnose(accessor->getLoc(), diag::objc_addressor);
        describeObjCReason(accessor, Reason);
      }
      return false;
    }
    llvm_unreachable("bad kind");
  }

  // As a special case, an initializer with a single, named parameter of type
  // '()' is always representable in Objective-C. This allows us to cope with
  // zero-parameter methods with selectors that are longer than "init". For
  // example, this allows:
  //
  // \code
  // class Foo {
  //   @objc init(malice: ()) { } // selector is "initWithMalice"
  // }
  // \endcode
  bool isSpecialInit = false;
  if (auto init = dyn_cast<ConstructorDecl>(AFD))
    isSpecialInit = init->isObjCZeroParameterWithLongSelector();

  if (!isSpecialInit &&
      !isParamListRepresentableInObjC(AFD,
                                      AFD->getParameterLists().back(),
                                      Reason)) {
    if (!Diagnose) {
      // Return as soon as possible if we are not producing diagnostics.
      return false;
    }
  }

  if (auto FD = dyn_cast<FuncDecl>(AFD)) {
    Type ResultType = FD->mapTypeIntoContext(FD->getResultInterfaceType());
    if (!ResultType->hasError() &&
        !ResultType->isVoid() &&
        !ResultType->isUninhabited() &&
        !ResultType->isRepresentableIn(ForeignLanguage::ObjectiveC,
                                       const_cast<FuncDecl *>(FD))) {
      if (Diagnose) {
        diagnose(AFD->getLoc(), diag::objc_invalid_on_func_result_type,
                 getObjCDiagnosticAttrKind(Reason));
        SourceRange Range =
            FD->getBodyResultTypeLoc().getTypeRepr()->getSourceRange();
        diagnoseTypeNotRepresentableInObjC(FD, ResultType, Range);
        describeObjCReason(FD, Reason);
      }
      return false;
    }
  }

  // Throwing functions must map to a particular error convention.
  if (AFD->hasThrows()) {
    DeclContext *dc = const_cast<AbstractFunctionDecl *>(AFD);
    SourceLoc throwsLoc;
    Type resultType;

    const ConstructorDecl *ctor = nullptr;
    if (auto func = dyn_cast<FuncDecl>(AFD)) {
      resultType = func->getResultInterfaceType();
      throwsLoc = func->getThrowsLoc();
    } else {
      ctor = cast<ConstructorDecl>(AFD);
      throwsLoc = ctor->getThrowsLoc();
    }

    ForeignErrorConvention::Kind kind;
    CanType errorResultType;
    Type optOptionalType;
    if (ctor) {
      // Initializers always use the nil result convention.
      kind = ForeignErrorConvention::NilResult;

      // Only non-failing initializers can throw.
      if (ctor->getFailability() != OTK_None) {
        if (Diagnose) {
          diagnose(AFD->getLoc(), diag::objc_invalid_on_failing_init,
                   getObjCDiagnosticAttrKind(Reason))
            .highlight(throwsLoc);
          describeObjCReason(AFD, Reason);
        }

        return false;
      }
    } else if (resultType->isVoid()) {
      // Functions that return nothing (void) can be throwing; they indicate
      // failure with a 'false' result.
      kind = ForeignErrorConvention::ZeroResult;
      NominalTypeDecl *boolDecl = Context.getObjCBoolDecl();
      // On Linux, we might still run @objc tests even though there's
      // no ObjectiveC Foundation, so use Swift.Bool instead of crapping
      // out.
      if (boolDecl == nullptr)
        boolDecl = Context.getBoolDecl();

      if (boolDecl == nullptr) {
        diagnose(AFD->getLoc(), diag::broken_bool);
        return false;
      }

      errorResultType = boolDecl->getDeclaredType()->getCanonicalType();
    } else if (!resultType->getOptionalObjectType() &&
               isBridgedToObjectiveCClass(dc, resultType)) {
      // Functions that return a (non-optional) type bridged to Objective-C
      // can be throwing; they indicate failure with a nil result.
      kind = ForeignErrorConvention::NilResult;
    } else if ((optOptionalType = resultType->getOptionalObjectType()) &&
               isBridgedToObjectiveCClass(dc, optOptionalType)) {
      // Cannot return an optional bridged type, because 'nil' is reserved
      // to indicate failure. Call this out in a separate diagnostic.
      if (Diagnose) {
        diagnose(AFD->getLoc(),
                 diag::objc_invalid_on_throwing_optional_result,
                 getObjCDiagnosticAttrKind(Reason),
                 resultType)
          .highlight(throwsLoc);
        describeObjCReason(AFD, Reason);
      }
      return false;
    } else {
      // Other result types are not permitted.
      if (Diagnose) {
        diagnose(AFD->getLoc(),
                 diag::objc_invalid_on_throwing_result,
                 getObjCDiagnosticAttrKind(Reason),
                 resultType)
          .highlight(throwsLoc);
        describeObjCReason(AFD, Reason);
      }
      return false;
    }

    // The error type is always 'AutoreleasingUnsafeMutablePointer<NSError?>?'.
    Type errorParameterType = getNSErrorType(dc);
    if (errorParameterType) {
      errorParameterType = OptionalType::get(errorParameterType);
      errorParameterType
        = BoundGenericType::get(
            Context.getAutoreleasingUnsafeMutablePointerDecl(),
            nullptr,
            errorParameterType);
      errorParameterType = OptionalType::get(errorParameterType);
    }

    // Determine the parameter index at which the error will go.
    unsigned errorParameterIndex;
    bool foundErrorParameterIndex = false;

    // If there is an explicit @objc attribute with a name, look for
    // the "error" selector piece.
    if (auto objc = AFD->getAttrs().getAttribute<ObjCAttr>()) {
      if (auto objcName = objc->getName()) {
        auto selectorPieces = objcName->getSelectorPieces();
        for (unsigned i = selectorPieces.size(); i > 0; --i) {
          // If the selector piece is "error", this is the location of
          // the error parameter.
          auto piece = selectorPieces[i-1];
          if (piece == Context.Id_error) {
            errorParameterIndex = i-1;
            foundErrorParameterIndex = true;
            break;
          }

          // If the first selector piece ends with "Error", it's here.
          if (i == 1 && camel_case::getLastWord(piece.str()) == "Error") {
            errorParameterIndex = i-1;
            foundErrorParameterIndex = true;
            break;
          }
        }
      }
    }

    // If the selector did not provide an index for the error, find
    // the last parameter that is not a trailing closure.
    if (!foundErrorParameterIndex) {
      auto *paramList = AFD->getParameterLists().back();
      errorParameterIndex = paramList->size();

      // Note: the errorParameterIndex is actually a SIL function
      // parameter index, which means tuples are exploded. Normally
      // tuple types cannot be bridged to Objective-C, except for
      // one special case -- a constructor with a single named parameter
      // 'foo' of tuple type becomes a zero-argument selector named
      // 'initFoo'.
      if (auto *CD = dyn_cast<ConstructorDecl>(AFD))
        if (CD->isObjCZeroParameterWithLongSelector())
          errorParameterIndex--;

      while (errorParameterIndex > 0) {
        // Skip over trailing closures.
        auto type = paramList->get(errorParameterIndex - 1)->getType();

        // It can't be a trailing closure unless it has a specific form.
        // Only consider the rvalue type.
        type = type->getRValueType();

        // Look through one level of optionality.
        if (auto objectType = type->getOptionalObjectType())
          type = objectType;

        // Is it a function type?
        if (!type->is<AnyFunctionType>()) break;
        --errorParameterIndex;
      }
    }

    // Form the error convention.
    CanType canErrorParameterType;
    if (errorParameterType)
      canErrorParameterType = errorParameterType->getCanonicalType();
    switch (kind) {
    case ForeignErrorConvention::ZeroResult:
      errorConvention = ForeignErrorConvention::getZeroResult(
                          errorParameterIndex,
                          ForeignErrorConvention::IsNotOwned,
                          ForeignErrorConvention::IsNotReplaced,
                          canErrorParameterType,
                          errorResultType);
      break;

    case ForeignErrorConvention::NonZeroResult:
      errorConvention = ForeignErrorConvention::getNonZeroResult(
                          errorParameterIndex,
                          ForeignErrorConvention::IsNotOwned,
                          ForeignErrorConvention::IsNotReplaced,
                          canErrorParameterType,
                          errorResultType);
      break;

    case ForeignErrorConvention::ZeroPreservedResult:
      errorConvention = ForeignErrorConvention::getZeroPreservedResult(
                          errorParameterIndex,
                          ForeignErrorConvention::IsNotOwned,
                          ForeignErrorConvention::IsNotReplaced,
                          canErrorParameterType);
      break;

    case ForeignErrorConvention::NilResult:
      errorConvention = ForeignErrorConvention::getNilResult(
                          errorParameterIndex,
                          ForeignErrorConvention::IsNotOwned,
                          ForeignErrorConvention::IsNotReplaced,
                          canErrorParameterType);
      break;

    case ForeignErrorConvention::NonNilError:
      errorConvention = ForeignErrorConvention::getNilResult(
                          errorParameterIndex,
                          ForeignErrorConvention::IsNotOwned,
                          ForeignErrorConvention::IsNotReplaced,
                          canErrorParameterType);
      break;
    }
  }

  return true;
}

bool TypeChecker::isRepresentableInObjC(const VarDecl *VD, ObjCReason Reason) {
  // If you change this function, you must add or modify a test in PrintAsObjC.

  if (VD->isInvalid())
    return false;

  Type T = VD->getDeclContext()->mapTypeIntoContext(VD->getInterfaceType());
  if (auto *RST = T->getAs<ReferenceStorageType>()) {
    // In-memory layout of @weak and @unowned does not correspond to anything
    // in Objective-C, but this does not really matter here, since Objective-C
    // uses getters and setters to operate on the property.
    // Because of this, look through @weak and @unowned.
    T = RST->getReferentType();
  }
  bool Result = T->isRepresentableIn(ForeignLanguage::ObjectiveC,
                                     VD->getDeclContext());
  bool Diagnose = shouldDiagnoseObjCReason(Reason, Context);

  if (Result && checkObjCInExtensionContext(VD, Diagnose))
    return false;

  if (checkObjCInForeignClassContext(VD, Reason))
    return false;

  if (!Diagnose || Result)
    return Result;

  SourceRange TypeRange = VD->getTypeSourceRangeForDiagnostics();
  // TypeRange can be invalid; e.g. '@objc let foo = SwiftType()'
  if (TypeRange.isInvalid())
    TypeRange = VD->getNameLoc();

  diagnose(VD->getLoc(), diag::objc_invalid_on_var,
           getObjCDiagnosticAttrKind(Reason))
      .highlight(TypeRange);
  diagnoseTypeNotRepresentableInObjC(VD->getDeclContext(),
                                     VD->getInterfaceType(),
                                     TypeRange);
  describeObjCReason(VD, Reason);

  return Result;
}

bool TypeChecker::isRepresentableInObjC(const SubscriptDecl *SD,
                                        ObjCReason Reason) {
  // If you change this function, you must add or modify a test in PrintAsObjC.

  bool Diagnose = shouldDiagnoseObjCReason(Reason, Context);

  if (checkObjCInForeignClassContext(SD, Reason))
    return false;

  // Figure out the type of the indices.
  Type IndicesType = SD->getIndicesInterfaceType()->getWithoutImmediateLabel();

  if (IndicesType->hasError())
    return false;

  bool IndicesResult =
    IndicesType->isRepresentableIn(ForeignLanguage::ObjectiveC,
                                   SD->getDeclContext());

  Type ElementType = SD->getElementInterfaceType();
  bool ElementResult = ElementType->isRepresentableIn(
        ForeignLanguage::ObjectiveC, SD->getDeclContext());
  bool Result = IndicesResult && ElementResult;

  if (Result && checkObjCInExtensionContext(SD, Diagnose))
    return false;

  // Make sure we know how to map the selector appropriately.
  if (Result && SD->getObjCSubscriptKind() == ObjCSubscriptKind::None) {
    SourceRange IndexRange = SD->getIndices()->getSourceRange();
    diagnose(SD->getLoc(), diag::objc_invalid_subscript_key_type,
             getObjCDiagnosticAttrKind(Reason), IndicesType)
      .highlight(IndexRange);
    return false;
  }

  if (!Diagnose || Result)
    return Result;

  SourceRange TypeRange;
  if (!IndicesResult)
    TypeRange = SD->getIndices()->getSourceRange();
  else
    TypeRange = SD->getElementTypeLoc().getSourceRange();
  diagnose(SD->getLoc(), diag::objc_invalid_on_subscript,
           getObjCDiagnosticAttrKind(Reason))
    .highlight(TypeRange);

  diagnoseTypeNotRepresentableInObjC(SD->getDeclContext(),
                                     !IndicesResult ? IndicesType
                                                    : ElementType,
                                     TypeRange);
  describeObjCReason(SD, Reason);

  return Result;
}

bool TypeChecker::canBeRepresentedInObjC(const ValueDecl *decl) {
  if (!Context.LangOpts.EnableObjCInterop)
    return false;

  if (auto func = dyn_cast<AbstractFunctionDecl>(decl)) {
    Optional<ForeignErrorConvention> errorConvention;
    return isRepresentableInObjC(func, ObjCReason::MemberOfObjCMembersClass,
                                 errorConvention);
  }

  if (auto var = dyn_cast<VarDecl>(decl))
    return isRepresentableInObjC(var, ObjCReason::MemberOfObjCMembersClass);

  if (auto subscript = dyn_cast<SubscriptDecl>(decl))
    return isRepresentableInObjC(subscript,
                                 ObjCReason::MemberOfObjCMembersClass);

  return false;
}

static Type getObjectiveCNominalType(Type &cache,
                                     Identifier ModuleName,
                                     Identifier TypeName,
                                     DeclContext *dc) {
  if (cache)
    return cache;

  // FIXME: Does not respect visibility of the module.
  ASTContext &ctx = dc->getASTContext();
  ModuleDecl *module = ctx.getLoadedModule(ModuleName);
  if (!module)
    return nullptr;

  SmallVector<ValueDecl *, 4> decls;
  NLOptions options = NL_QualifiedDefault | NL_OnlyTypes;
  dc->lookupQualified(ModuleType::get(module), TypeName, options, nullptr,
                      decls);
  for (auto decl : decls) {
    if (auto nominal = dyn_cast<NominalTypeDecl>(decl)) {
      cache = nominal->getDeclaredType();
      return cache;
    }
  }

  return nullptr;
}

static void lookupAndAddLibraryTypes(TypeChecker &TC,
                                     ModuleDecl *Stdlib,
                                     ArrayRef<Identifier> TypeNames,
                                     llvm::DenseSet<CanType> &Types) {
  SmallVector<ValueDecl *, 4> Results;
  for (Identifier Id : TypeNames) {
    Stdlib->lookupValue({}, Id, NLKind::UnqualifiedLookup, Results);
    for (auto *VD : Results) {
      if (auto *TD = dyn_cast<TypeDecl>(VD)) {
        TC.validateDecl(TD);
        Types.insert(TD->getDeclaredInterfaceType()->getCanonicalType());
      }
    }
    Results.clear();
  }
}

void TypeChecker::fillObjCRepresentableTypeCache(const DeclContext *DC) {
  if (!CIntegerTypes.empty())
    return;

  SmallVector<Identifier, 32> StdlibTypeNames;
  ModuleDecl *Stdlib = getStdlibModule(DC);
#define MAP_BUILTIN_TYPE(_, __)
#define MAP_BUILTIN_INTEGER_TYPE(CLANG_BUILTIN_KIND, SWIFT_TYPE_NAME) \
  StdlibTypeNames.push_back(Context.getIdentifier(#SWIFT_TYPE_NAME));
#include "swift/ClangImporter/BuiltinMappedTypes.def"
  lookupAndAddLibraryTypes(*this, Stdlib, StdlibTypeNames, CIntegerTypes);
}

#pragma mark Objective-C-specific types

Type TypeChecker::getNSObjectType(DeclContext *dc) {
  return getObjectiveCNominalType(NSObjectType, Context.Id_ObjectiveC,
                                Context.getSwiftId(
                                  KnownFoundationEntity::NSObject),
                                dc);
}

Type TypeChecker::getNSErrorType(DeclContext *dc) {
  return getObjectiveCNominalType(NSErrorType, Context.Id_Foundation,
                                  Context.getSwiftId(
                                    KnownFoundationEntity::NSError),
                                  dc);
}

Type TypeChecker::getObjCSelectorType(DeclContext *dc) {
  return getObjectiveCNominalType(ObjCSelectorType,
                                  Context.Id_ObjectiveC,
                                  Context.Id_Selector,
                                  dc);
}

#pragma mark Bridging support

/// Check runtime functions responsible for implicit bridging of Objective-C
/// types.
static void checkObjCBridgingFunctions(TypeChecker &TC,
                                       ModuleDecl *mod,
                                       StringRef bridgedTypeName,
                                       StringRef forwardConversion,
                                       StringRef reverseConversion) {
  assert(mod);
  ModuleDecl::AccessPathTy unscopedAccess = {};
  SmallVector<ValueDecl *, 4> results;

  auto &Ctx = TC.Context;
  mod->lookupValue(unscopedAccess, Ctx.getIdentifier(bridgedTypeName),
                   NLKind::QualifiedLookup, results);
  mod->lookupValue(unscopedAccess, Ctx.getIdentifier(forwardConversion),
                   NLKind::QualifiedLookup, results);
  mod->lookupValue(unscopedAccess, Ctx.getIdentifier(reverseConversion),
                   NLKind::QualifiedLookup, results);

  for (auto D : results)
    TC.validateDecl(D);
}

static void checkBridgedFunctions(TypeChecker &TC) {
  if (TC.HasCheckedBridgeFunctions)
    return;

  TC.HasCheckedBridgeFunctions = true;

  #define BRIDGE_TYPE(BRIDGED_MOD, BRIDGED_TYPE, _, NATIVE_TYPE, OPT) \
  Identifier ID_##BRIDGED_MOD = TC.Context.getIdentifier(#BRIDGED_MOD);\
  if (ModuleDecl *module = TC.Context.getLoadedModule(ID_##BRIDGED_MOD)) {\
    checkObjCBridgingFunctions(TC, module, #BRIDGED_TYPE, \
    "_convert" #BRIDGED_TYPE "To" #NATIVE_TYPE, \
    "_convert" #NATIVE_TYPE "To" #BRIDGED_TYPE); \
  }
  #include "swift/SIL/BridgedTypes.def"

  if (ModuleDecl *module = TC.Context.getLoadedModule(TC.Context.Id_Foundation)) {
    checkObjCBridgingFunctions(TC, module,
                               TC.Context.getSwiftName(
                                 KnownFoundationEntity::NSError),
                               "_convertNSErrorToError",
                               "_convertErrorToNSError");
  }
}

#pragma mark @objc declaration handling

/// Whether this declaration is a member of a class extension marked @objc.
static bool isMemberOfObjCClassExtension(const ValueDecl *VD) {
  auto ext = dyn_cast<ExtensionDecl>(VD->getDeclContext());
  if (!ext) return false;

  return ext->getAsClassOrClassExtensionContext() &&
    ext->getAttrs().hasAttribute<ObjCAttr>();
}

/// Whether this declaration is a member of a class with the `@objcMembers`
/// attribute.
static bool isMemberOfObjCMembersClass(const ValueDecl *VD) {
  auto classDecl = VD->getDeclContext()->getAsClassOrClassExtensionContext();
  if (!classDecl) return false;

  return classDecl->getAttrs().hasAttribute<ObjCMembersAttr>();
}

// A class is @objc if it does not have generic ancestry, and it either has
// an explicit @objc attribute, or its superclass is @objc.
static Optional<ObjCReason> shouldMarkClassAsObjC(TypeChecker &TC,
                                                  const ClassDecl *CD) {
  ObjCClassKind kind = CD->checkObjCAncestry();

  if (auto attr = CD->getAttrs().getAttribute<ObjCAttr>()) {
    if (kind == ObjCClassKind::ObjCMembers) {
      if (attr->hasName() && !CD->isGenericContext()) {
        // @objc with a name on a non-generic subclass of a generic class is
        // just controlling the runtime name. Don't diagnose this case.
        const_cast<ClassDecl *>(CD)->getAttrs().add(
          new (TC.Context) ObjCRuntimeNameAttr(*attr));
        return None;
      }

      TC.diagnose(attr->getLocation(), diag::objc_for_generic_class)
        .fixItRemove(attr->getRangeWithAt());
    }

    // Only allow ObjC-rooted classes to be @objc.
    // (Leave a hole for test cases.)
    if (kind == ObjCClassKind::ObjCWithSwiftRoot) {
      if (TC.getLangOpts().EnableObjCAttrRequiresFoundation)
        TC.diagnose(attr->getLocation(), diag::invalid_objc_swift_rooted_class)
          .fixItRemove(attr->getRangeWithAt());
      if (!TC.getLangOpts().EnableObjCInterop)
        TC.diagnose(attr->getLocation(), diag::objc_interop_disabled)
          .fixItRemove(attr->getRangeWithAt());
    }

    return ObjCReason(ObjCReason::ExplicitlyObjC);
  }

  if (kind == ObjCClassKind::ObjCWithSwiftRoot ||
      kind == ObjCClassKind::ObjC)
    return ObjCReason(ObjCReason::ImplicitlyObjC);

  return None;
}

/// Figure out if a declaration should be exported to Objective-C.
Optional<ObjCReason> swift::shouldMarkAsObjC(TypeChecker &TC,
                                             const ValueDecl *VD,
                                             bool allowImplicit) {
  if (auto classDecl = dyn_cast<ClassDecl>(VD)) {
    return shouldMarkClassAsObjC(TC, classDecl);
  }

  ProtocolDecl *protocolContext =
      dyn_cast<ProtocolDecl>(VD->getDeclContext());
  bool isMemberOfObjCProtocol =
      protocolContext && protocolContext->isObjC();

  // Local function to determine whether we can implicitly infer @objc.
  auto canInferImplicitObjC = [&] {
    if (VD->isInvalid())
      return false;
    if (VD->isOperator())
      return false;

    // Implicitly generated declarations are not @objc, except for constructors.
    if (!allowImplicit && VD->isImplicit())
      return false;

    if (VD->getFormalAccess() <= AccessLevel::FilePrivate)
      return false;

    return true;
  };

  // explicitly declared @objc.
  if (VD->getAttrs().hasAttribute<ObjCAttr>())
    return ObjCReason(ObjCReason::ExplicitlyObjC);
  // @IBOutlet, @IBAction, @NSManaged, and @GKInspectable imply @objc.
  //
  // @IBInspectable and @GKInspectable imply @objc quietly in Swift 3
  // (where they warn on failure) and loudly in Swift 4 (error on failure).
  if (VD->getAttrs().hasAttribute<IBOutletAttr>())
    return ObjCReason(ObjCReason::ExplicitlyIBOutlet);
  if (VD->getAttrs().hasAttribute<IBActionAttr>())
    return ObjCReason(ObjCReason::ExplicitlyIBAction);
  if (VD->getAttrs().hasAttribute<IBInspectableAttr>())
    return ObjCReason(ObjCReason::ExplicitlyIBInspectable);
  if (VD->getAttrs().hasAttribute<GKInspectableAttr>())
    return ObjCReason(ObjCReason::ExplicitlyGKInspectable);
  if (VD->getAttrs().hasAttribute<NSManagedAttr>())
    return ObjCReason(ObjCReason::ExplicitlyNSManaged);
  // A member of an @objc protocol is implicitly @objc.
  if (isMemberOfObjCProtocol)
    return ObjCReason(ObjCReason::MemberOfObjCProtocol);
  // A @nonobjc is not @objc, even if it is an override of an @objc, so check
  // for @nonobjc first.
  if (VD->getAttrs().hasAttribute<NonObjCAttr>() ||
      (isa<ExtensionDecl>(VD->getDeclContext()) &&
       cast<ExtensionDecl>(VD->getDeclContext())->getAttrs()
        .hasAttribute<NonObjCAttr>()))
    return None;
  if (isMemberOfObjCClassExtension(VD))
    return ObjCReason(ObjCReason::MemberOfObjCExtension);
  if (isMemberOfObjCMembersClass(VD) && canInferImplicitObjC())
    return ObjCReason(ObjCReason::MemberOfObjCMembersClass);
  // An override of an @objc declaration is implicitly @objc.
  if (VD->getOverriddenDecl() && VD->getOverriddenDecl()->isObjC())
    return ObjCReason(ObjCReason::OverridesObjC);
  // A witness to an @objc protocol requirement is implicitly @objc.
  if (VD->getDeclContext()->getAsClassOrClassExtensionContext()) {
    auto requirements =
      TC.findWitnessedObjCRequirements(VD, /*anySingleRequirement=*/true);
    if (!requirements.empty())
      return ObjCReason::witnessToObjC(requirements.front());
  }

  // Infer '@objc' for 'dynamic' members.
  if (auto attr = VD->getAttrs().getAttribute<DynamicAttr>()) {
    // For implicit 'dynamic', just infer '@objc' implicitly.
    if (attr->isImplicit())
      return ObjCReason(ObjCReason::ImplicitlyObjC);

    bool isGetterOrSetter =
      isa<AccessorDecl>(VD) && cast<AccessorDecl>(VD)->isGetterOrSetter();

    // Under Swift 3's @objc inference rules, 'dynamic' infers '@objc'.
    if (TC.Context.LangOpts.EnableSwift3ObjCInference) {
      // If we've been asked to warn about deprecated @objc inference, do so
      // now.
      if (TC.Context.LangOpts.WarnSwift3ObjCInference !=
            Swift3ObjCInferenceWarnings::None &&
          !isGetterOrSetter) {
        TC.diagnose(VD, diag::objc_inference_swift3_dynamic)
          .highlight(attr->getLocation())
          .fixItInsert(VD->getAttributeInsertionLoc(/*forModifier=*/false),
                      "@objc ");
      }

      return ObjCReason(ObjCReason::ExplicitlyDynamic);
    }

    // Complain that 'dynamic' requires '@objc', but (quietly) infer @objc
    // anyway for better recovery.
    TC.diagnose(VD, diag::dynamic_requires_objc,
                VD->getDescriptiveKind(), VD->getFullName())
      .highlight(attr->getRange())
      .fixItInsert(VD->getAttributeInsertionLoc(/*forModifier=*/false),
                   "@objc ");

    return ObjCReason(ObjCReason::ImplicitlyObjC);
  }

  // If we aren't provided Swift 3's @objc inference rules, we're done.
  if (!TC.Context.LangOpts.EnableSwift3ObjCInference)
    return None;

  // Infer '@objc' for valid, non-implicit, non-operator, members of classes
  // (and extensions thereof) whose class hierarchies originate in Objective-C,
  // e.g., which derive from NSObject, so long as the members have internal
  // access or greater.
  if (!canInferImplicitObjC())
    return None;

  // If this declaration is part of a class with implicitly @objc members,
  // make it implicitly @objc. However, if the declaration cannot be represented
  // as @objc, don't diagnose.
  if (auto classDecl = VD->getDeclContext()
          ->getAsClassOrClassExtensionContext()) {
    // One cannot define @objc members of any foreign classes.
    if (classDecl->isForeign())
      return None;

    if (classDecl->checkObjCAncestry() != ObjCClassKind::NonObjC) {
      return VD->isImplicit() ? ObjCReason(ObjCReason::ImplicitlyObjC)
                              : ObjCReason(ObjCReason::MemberOfObjCSubclass);
    }
  }

  return None;
}

/// Infer the Objective-C name for a given declaration.
static void inferObjCName(TypeChecker &tc, ValueDecl *decl) {
  if (isa<DestructorDecl>(decl))
    return;

  assert(decl->isObjC() && "Must be known to be @objc");
  auto attr = decl->getAttrs().getAttribute<ObjCAttr>();

  /// Set the @objc name.
  auto setObjCName = [&](ObjCSelector selector) {
    // If there already is an @objc attribute, update its name.
    if (attr) {
      const_cast<ObjCAttr *>(attr)->setName(selector, /*implicit=*/true);
      return;
    }

    // Otherwise, create an @objc attribute with the implicit name.
    attr = ObjCAttr::create(tc.Context, selector, /*implicitName=*/true);
    decl->getAttrs().add(attr);
  };

  // If this declaration overrides an @objc declaration, use its name.
  if (auto overridden = decl->getOverriddenDecl()) {
    if (overridden->isObjC()) {
      // Handle methods first.
      if (auto overriddenFunc = dyn_cast<AbstractFunctionDecl>(overridden)) {
        // Determine the selector of the overridden method.
        ObjCSelector overriddenSelector = overriddenFunc->getObjCSelector();

        // Determine whether there is a name conflict.
        bool shouldFixName = !attr || !attr->hasName();
        if (attr && attr->hasName() && *attr->getName() != overriddenSelector) {
          // If the user explicitly wrote the incorrect name, complain.
          if (!attr->isNameImplicit()) {
            {
              auto diag = tc.diagnose(
                            attr->AtLoc,
                            diag::objc_override_method_selector_mismatch,
                            *attr->getName(), overriddenSelector);
              fixDeclarationObjCName(diag, decl, overriddenSelector);
            }

            tc.diagnose(overriddenFunc, diag::overridden_here);
          }

          shouldFixName = true;
        }

        // If we have to set the name, do so.
        if (shouldFixName) {
          // Override the name on the attribute.
          setObjCName(overriddenSelector);
        }
        return;
      }

      // Handle properties.
      if (auto overriddenProp = dyn_cast<VarDecl>(overridden)) {
        Identifier overriddenName = overriddenProp->getObjCPropertyName();
        ObjCSelector overriddenNameAsSel(tc.Context, 0, overriddenName);

        // Determine whether there is a name conflict.
        bool shouldFixName = !attr || !attr->hasName();
        if (attr && attr->hasName() &&
            *attr->getName() != overriddenNameAsSel) {
          // If the user explicitly wrote the wrong name, complain.
          if (!attr->isNameImplicit()) {
            tc.diagnose(attr->AtLoc,
                        diag::objc_override_property_name_mismatch,
                        attr->getName()->getSelectorPieces()[0],
                        overriddenName)
              .fixItReplaceChars(attr->getNameLocs().front(),
                                 attr->getRParenLoc(),
                                 overriddenName.str());
            tc.diagnose(overridden, diag::overridden_here);
          }

          shouldFixName = true;
        }

        // Fix the name, if needed.
        if (shouldFixName) {
          setObjCName(overriddenNameAsSel);
        }
        return;
      }
    }
  }

  // If the decl already has a name, do nothing; the protocol conformance
  // checker will handle any mismatches.
  if (attr && attr->hasName()) return;

  // When no override determined the Objective-C name, look for
  // requirements for which this declaration is a witness.
  Optional<ObjCSelector> requirementObjCName;
  ValueDecl *firstReq = nullptr;
  for (auto req : tc.findWitnessedObjCRequirements(decl)) {
    // If this is the first requirement, take its name.
    if (!requirementObjCName) {
      requirementObjCName = req->getObjCRuntimeName();
      firstReq = req;
      continue;
    }

    // If this requirement has a different name from one we've seen,
    // note the ambiguity.
    if (*requirementObjCName != *req->getObjCRuntimeName()) {
      tc.diagnose(decl, diag::objc_ambiguous_inference,
                  decl->getDescriptiveKind(), decl->getFullName(),
                  *requirementObjCName, *req->getObjCRuntimeName());

      // Note the candidates and what Objective-C names they provide.
      auto diagnoseCandidate = [&](ValueDecl *req) {
        auto proto = cast<ProtocolDecl>(req->getDeclContext());
        auto diag = tc.diagnose(decl,
                                diag::objc_ambiguous_inference_candidate,
                                req->getFullName(),
                                proto->getFullName(),
                                *req->getObjCRuntimeName());
        fixDeclarationObjCName(diag, decl, req->getObjCRuntimeName());
      };
      diagnoseCandidate(firstReq);
      diagnoseCandidate(req);

      // Suggest '@nonobjc' to suppress this error, and not try to
      // infer @objc for anything.
      tc.diagnose(decl, diag::req_near_match_nonobjc, true)
        .fixItInsert(decl->getAttributeInsertionLoc(false), "@nonobjc ");
      break;
    }
  }

  // If we have a name, install it via an @objc attribute.
  if (requirementObjCName) {
    setObjCName(*requirementObjCName);
  }
}

/// Mark the given declaration as being Objective-C compatible (or
/// not) as appropriate.
///
/// If the declaration has a @nonobjc attribute, diagnose an error
/// using the given Reason, if present.
void swift::markAsObjC(TypeChecker &TC, ValueDecl *D,
                       Optional<ObjCReason> isObjC,
                       Optional<ForeignErrorConvention> errorConvention) {
  D->setIsObjC(isObjC.hasValue());

  if (!isObjC) {
    // FIXME: For now, only @objc declarations can be dynamic.
    if (auto attr = D->getAttrs().getAttribute<DynamicAttr>())
      attr->setInvalid();
    return;
  }

  // By now, the caller will have handled the case where an implicit @objc
  // could be overridden by @nonobjc. If we see a @nonobjc and we are trying
  // to add an @objc for whatever reason, diagnose an error.
  if (auto *attr = D->getAttrs().getAttribute<NonObjCAttr>()) {
    if (!shouldDiagnoseObjCReason(*isObjC, TC.Context))
      isObjC = ObjCReason::ImplicitlyObjC;

    TC.diagnose(D->getStartLoc(), diag::nonobjc_not_allowed,
                getObjCDiagnosticAttrKind(*isObjC));

    attr->setInvalid();
  }

  // Make sure we have the appropriate bridging operations.
  if (!isa<DestructorDecl>(D))
    checkBridgedFunctions(TC);
  TC.useObjectiveCBridgeableConformances(D->getInnermostDeclContext(),
                                         D->getInterfaceType());

  // Record the name of this Objective-C method in its class.
  if (auto classDecl
        = D->getDeclContext()->getAsClassOrClassExtensionContext()) {
    if (auto method = dyn_cast<AbstractFunctionDecl>(D)) {
      // Determine the foreign error convention.
      if (auto baseMethod = method->getOverriddenDecl()) {
        // If the overridden method has a foreign error convention,
        // adopt it.  Set the foreign error convention for a throwing
        // method.  Note that the foreign error convention affects the
        // selector, so we perform this before inferring a selector.
        if (method->hasThrows()) {
          if (auto baseErrorConvention
                = baseMethod->getForeignErrorConvention()) {
            errorConvention = baseErrorConvention;
          }

          assert(errorConvention && "Missing error convention");
          method->setForeignErrorConvention(*errorConvention);
        }
      } else if (method->hasThrows()) {
        // Attach the foreign error convention.
        assert(errorConvention && "Missing error convention");
        method->setForeignErrorConvention(*errorConvention);
      }

      // Infer the Objective-C name for this method.
      inferObjCName(TC, method);

      // ... then record it.
      classDecl->recordObjCMethod(method);

      // Swift does not permit class methods with Objective-C selectors 'load',
      // 'alloc', or 'allocWithZone:'.
      if (!method->isInstanceMember()) {
        auto isForbiddenSelector = [&TC](ObjCSelector sel)
        -> Optional<Diag<unsigned, DeclName, ObjCSelector>> {
          switch (sel.getNumArgs()) {
          case 0:
            if (sel.getSelectorPieces().front() == TC.Context.Id_load ||
                sel.getSelectorPieces().front() == TC.Context.Id_alloc)
              return diag::objc_class_method_not_permitted;
            // Swift 3 and earlier allowed you to override `initialize`, but
            // Swift's semantics do not guarantee that it will be called at
            // the point you expect. It is disallowed in Swift 4 and later.
            if (sel.getSelectorPieces().front() == TC.Context.Id_initialize) {
              if (TC.getLangOpts().isSwiftVersion3())
                return
                  diag::objc_class_method_not_permitted_swift3_compat_warning;
              else
                return diag::objc_class_method_not_permitted;
            }
            return None;
          case 1:
            if (sel.getSelectorPieces().front() == TC.Context.Id_allocWithZone)
              return diag::objc_class_method_not_permitted;
            return None;
          default:
            return None;
          }
        };
        auto sel = method->getObjCSelector();
        if (auto diagID = isForbiddenSelector(sel)) {
          auto diagInfo = getObjCMethodDiagInfo(method);
          TC.diagnose(method, *diagID,
                      diagInfo.first, diagInfo.second, sel);
        }
      }
    } else if (isa<VarDecl>(D)) {
      // Infer the Objective-C name for this property.
      inferObjCName(TC, D);
    }
  } else if (auto method = dyn_cast<AbstractFunctionDecl>(D)) {
    if (method->hasThrows()) {
      // Attach the foreign error convention.
      assert(errorConvention && "Missing error convention");
      method->setForeignErrorConvention(*errorConvention);
    }
  }

  // Record this method in the source-file-specific Objective-C method
  // table.
  if (auto method = dyn_cast<AbstractFunctionDecl>(D)) {
    if (auto sourceFile = method->getParentSourceFile()) {
      sourceFile->ObjCMethods[method->getObjCSelector()].push_back(method);
    }
  }

  // Special handling for Swift 3 @objc inference rules that are no longer
  // present in later versions of Swift.
  if (*isObjC == ObjCReason::MemberOfObjCSubclass) {
    // If we've been asked to unconditionally warn about these deprecated
    // @objc inference rules, do so now. However, we don't warn about
    // accessors---just the main storage declarations.
    if (TC.Context.LangOpts.WarnSwift3ObjCInference ==
          Swift3ObjCInferenceWarnings::Complete &&
        !(isa<AccessorDecl>(D) && cast<AccessorDecl>(D)->isGetterOrSetter())) {
      TC.diagnose(D, diag::objc_inference_swift3_objc_derived);
      TC.diagnose(D, diag::objc_inference_swift3_addobjc)
        .fixItInsert(D->getAttributeInsertionLoc(/*forModifier=*/false),
                     "@objc ");
      TC.diagnose(D, diag::objc_inference_swift3_addnonobjc)
        .fixItInsert(D->getAttributeInsertionLoc(/*forModifier=*/false),
                     "@nonobjc ");
    }

    // Mark the attribute as having used Swift 3 inference, or create an
    // implicit @objc for that purpose.
    auto attr = D->getAttrs().getAttribute<ObjCAttr>();
    if (!attr) {
      attr = ObjCAttr::createUnnamedImplicit(TC.Context);
      D->getAttrs().add(attr);
    }
    attr->setSwift3Inferred();
  }
}